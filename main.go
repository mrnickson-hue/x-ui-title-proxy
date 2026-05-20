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
	version           = "1.2.0"
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

// stripWebDomain removes webDomain from a JSON settings payload.
// 3X-UI's webDomain setting enables host-based filtering that blocks all proxy
// requests with 403. Stripping it here prevents accidental self-lockout via the UI.
func stripWebDomain(body []byte) []byte {
	var data map[string]interface{}
	if err := json.Unmarshal(body, &data); err != nil {
		return body
	}
	val, ok := data["webDomain"]
	if !ok || val == "" || val == nil {
		return body
	}
	data["webDomain"] = ""
	result, err := json.Marshal(data)
	if err != nil {
		return body
	}
	log.Printf("x-ui-proxy: stripped webDomain=%q from settings request", val)
	return result
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

		// Intercept POST requests and strip webDomain from JSON bodies
		if req.Method == http.MethodPost && req.Body != nil {
			body, err := io.ReadAll(req.Body)
			req.Body.Close()
			if err == nil {
				body = stripWebDomain(body)
			}
			req.Body = io.NopCloser(bytes.NewReader(body))
			req.ContentLength = int64(len(body))
		}
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

	log.Printf("x-ui-proxy v%s: listening on %s → %s", version, cfg.Listen, cfg.Backend)
	log.Fatal((&http.Server{
		Addr:    cfg.Listen,
		Handler: proxy,
	}).ListenAndServeTLS(cfg.Cert, cfg.Key))
}
