// Package ipunion 提供模块 http.ip_sources.union。
//
// 背景：Caddy 的 trusted_proxies 是「单源」字段（json `inline_key=source`，一个 server 只能配一个
// http.ip_sources.* 模块）。但实际部署经常需要同时信任两拨来源，例如：
//   - Cloudflare 官方 IP 段（动态拉取，插件 WeidiDeng/caddy-cloudflare-ip）
//   - 局域网 / Docker 网段（Swarm ingress 会把回源源 IP 变成 10.0.0.2，静态段最省事）
//
// 这个模块把任意多个 http.ip_sources.* 子模块的 IP 段取并集（自动去重），
// 于是可以用一个源表达「CF 段 + 内网段」。
//
// Caddyfile 用法：
//
//	{
//		servers {
//			trusted_proxies union {
//				source cloudflare {
//					interval 6h
//					timeout 10s
//				}
//				source static private_ranges 10.0.0.0/8
//			}
//		}
//	}
//
// JSON 等价写法：
//
//	"trusted_proxies": {
//		"source": "union",
//		"sources": [
//			{"source": "cloudflare", "interval": 21600000000000, "timeout": 10000000000},
//			{"source": "static", "ranges": ["10.0.0.0/8"]}
//		]
//	}
package ipunion

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/netip"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
)

func init() {
	caddy.RegisterModule(Union{})
}

// Union 是「多源并集」的 IP range source。
type Union struct {
	// 子模块列表，每个元素形如 {"source": "<模块名>", ...该模块自己的配置}
	Sources []json.RawMessage `json:"sources,omitempty" caddy:"namespace=http.ip_sources inline_key=source"`

	sources []caddyhttp.IPRangeSource
}

// CaddyModule 返回模块信息。
func (Union) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "http.ip_sources.union",
		New: func() caddy.Module { return new(Union) },
	}
}

// Provision 加载所有子模块。
func (u *Union) Provision(ctx caddy.Context) error {
	if len(u.Sources) == 0 {
		return fmt.Errorf("union 至少需要一个 source 子模块")
	}
	mods, err := ctx.LoadModule(u, "Sources")
	if err != nil {
		return fmt.Errorf("加载 sources 失败: %v", err)
	}
	for _, m := range mods.([]any) {
		src, ok := m.(caddyhttp.IPRangeSource)
		if !ok {
			return fmt.Errorf("%T 没有实现 http.ip_sources 接口", m)
		}
		u.sources = append(u.sources, src)
	}
	return nil
}

// GetIPRanges 返回所有子源的并集（去重，保持顺序稳定：自定义段在后更直观，所以不排序）。
func (u *Union) GetIPRanges(r *http.Request) []netip.Prefix {
	out := make([]netip.Prefix, 0, 48)
	seen := make(map[string]struct{}, 48)
	for _, src := range u.sources {
		for _, p := range src.GetIPRanges(r) {
			key := p.String()
			if _, dup := seen[key]; dup {
				continue
			}
			seen[key] = struct{}{}
			out = append(out, p)
		}
	}
	return out
}

// UnmarshalCaddyfile 解析：
//
//	union {
//		source <模块名> [参数...] [{ ... }]
//		...
//	}
func (u *Union) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	d.Next() // 跳过模块名 union
	if d.NextArg() {
		return d.ArgErr()
	}
	for nesting := d.Nesting(); d.NextBlock(nesting); {
		switch d.Val() {
		case "source":
			if !d.NextArg() {
				return d.ArgErr()
			}
			modID := "http.ip_sources." + d.Val()
			unm, err := caddyfile.UnmarshalModule(d, modID)
			if err != nil {
				return err
			}
			src, ok := unm.(caddyhttp.IPRangeSource)
			if !ok {
				return d.Errf("模块 %s 不是 IP range source", modID)
			}
			u.Sources = append(u.Sources, caddyconfig.JSONModuleObject(
				src, "source", src.(caddy.Module).CaddyModule().ID.Name(), nil,
			))
		default:
			return d.Errf("union 块里只支持 source，收到 %s", d.Val())
		}
	}
	return nil
}

// 接口断言
var (
	_ caddy.Module             = (*Union)(nil)
	_ caddy.Provisioner        = (*Union)(nil)
	_ caddyhttp.IPRangeSource  = (*Union)(nil)
	_ caddyfile.Unmarshaler    = (*Union)(nil)
)
