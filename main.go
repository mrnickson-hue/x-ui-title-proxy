package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
)

const (
	defaultConfigFile = "/etc/x-ui-proxy/config.json"
	version           = "1.4.0"
)

type Config struct {
	Listen  string `json:"listen"`
	Backend string `json:"backend"`
	Cert    string `json:"cert"`
	Key     string `json:"key"`
	Title   string `json:"title"`
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func extractNonce(csp string) string {
	const prefix = "nonce-"
	idx := strings.Index(csp, prefix)
	if idx == -1 {
		return ""
	}
	rest := csp[idx+len(prefix):]
	end := strings.IndexAny(rest, "' ")
	if end == -1 {
		return rest
	}
	return rest[:end]
}

// stripWebDomainJSON removes webDomain from a JSON body.
func stripWebDomainJSON(body []byte) ([]byte, bool) {
	var data map[string]interface{}
	if err := json.Unmarshal(body, &data); err != nil {
		return body, false
	}
	val, ok := data["webDomain"]
	if !ok || val == "" || val == nil {
		return body, false
	}
	data["webDomain"] = ""
	result, err := json.Marshal(data)
	if err != nil {
		return body, false
	}
	log.Printf("x-ui-proxy: stripped webDomain=%q (json)", val)
	return result, true
}

// stripWebDomainForm removes webDomain from a form-encoded body.
func stripWebDomainForm(body []byte) ([]byte, bool) {
	vals, err := url.ParseQuery(string(body))
	if err != nil {
		return body, false
	}
	val := vals.Get("webDomain")
	if val == "" {
		return body, false
	}
	vals.Set("webDomain", "")
	log.Printf("x-ui-proxy: stripped webDomain=%q (form)", val)
	return []byte(vals.Encode()), true
}

// isWebSocketUpgrade reports whether the request is a WebSocket upgrade.
func isWebSocketUpgrade(req *http.Request) bool {
	return strings.EqualFold(req.Header.Get("Upgrade"), "websocket") &&
		strings.Contains(strings.ToLower(req.Header.Get("Connection")), "upgrade")
}

// proxyWebSocket tunnels a WebSocket connection to the backend via raw TCP.
// httputil.ReverseProxy strips hop-by-hop headers and cannot handle the protocol
// switch, so we hijack the client connection and pipe it directly.
func proxyWebSocket(w http.ResponseWriter, req *http.Request, backendHost string) {
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "websocket not supported", http.StatusInternalServerError)
		return
	}
	clientConn, _, err := hijacker.Hijack()
	if err != nil {
		log.Printf("x-ui-proxy: ws hijack: %v", err)
		return
	}
	defer clientConn.Close()

	backendConn, err := tls.Dial("tcp", backendHost, &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		log.Printf("x-ui-proxy: ws dial backend: %v", err)
		return
	}
	defer backendConn.Close()

	req.Host = backendHost
	if err := req.Write(backendConn); err != nil {
		log.Printf("x-ui-proxy: ws write request: %v", err)
		return
	}

	done := make(chan struct{}, 2)
	go func() { io.Copy(backendConn, clientConn); done <- struct{}{} }()
	go func() { io.Copy(clientConn, backendConn); done <- struct{}{} }()
	<-done
}

// stripWebDomain strips webDomain from a POST body regardless of content type.
func stripWebDomain(body []byte, contentType string) []byte {
	if strings.Contains(contentType, "application/json") {
		result, _ := stripWebDomainJSON(body)
		return result
	}
	if strings.Contains(contentType, "application/x-www-form-urlencoded") {
		result, _ := stripWebDomainForm(body)
		return result
	}
	// Unknown content type — try JSON, fall back to original
	if result, ok := stripWebDomainJSON(body); ok {
		return result
	}
	return body
}

func main() {
	configPath := flag.String("config", defaultConfigFile, "path to config file")
	versionFlag := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *versionFlag {
		fmt.Println(version)
		os.Exit(0)
	}

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	target, err := url.Parse(cfg.Backend)
	if err != nil {
		log.Fatalf("invalid backend URL: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}

	orig := proxy.Director
	proxy.Director = func(req *http.Request) {
		orig(req)
		req.Header.Del("Accept-Encoding")
		req.Host = target.Host
	}

	proxy.ModifyResponse = func(resp *http.Response) error {
		ct := resp.Header.Get("Content-Type")
		if !strings.HasPrefix(ct, "text/html") {
			return nil
		}

		// Reload config on every request so title changes take effect without restart
		currentCfg, err := loadConfig(*configPath)
		if err != nil || currentCfg.Title == "" {
			return nil
		}
		title := currentCfg.Title

		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return err
		}

		nonce := extractNonce(resp.Header.Get("Content-Security-Policy"))
		nonceAttr := ""
		if nonce != "" {
			nonceAttr = fmt.Sprintf(` nonce="%s"`, nonce)
		}

		escaped := strings.ReplaceAll(title, "'", "\\'")
		script := fmt.Sprintf(
			`<script%s>document.addEventListener('DOMContentLoaded',function(){`+
				`var t=document.title,i=t.indexOf(' - ');`+
				`document.title=i>-1?'%s'+t.slice(i):'%s';`+
				`});</script>`,
			nonceAttr, escaped, escaped,
		)

		body = bytes.Replace(body, []byte("</head>"), append([]byte(script), []byte("</head>")...), 1)
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = int64(len(body))
		resp.Header.Del("Content-Encoding")
		return nil
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if isWebSocketUpgrade(req) {
			proxyWebSocket(w, req, target.Host)
			return
		}
		if req.Method == http.MethodPost && req.Body != nil {
			body, err := io.ReadAll(req.Body)
			req.Body.Close()
			if err == nil {
				body = stripWebDomain(body, req.Header.Get("Content-Type"))
			}
			req.Body = io.NopCloser(bytes.NewReader(body))
			req.ContentLength = int64(len(body))
		}
		proxy.ServeHTTP(w, req)
	})

	log.Printf("x-ui-proxy v%s: listening on %s → %s", version, cfg.Listen, cfg.Backend)
	log.Fatal((&http.Server{
		Addr:    cfg.Listen,
		Handler: handler,
	}).ListenAndServeTLS(cfg.Cert, cfg.Key))
}
