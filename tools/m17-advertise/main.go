// m17-advertise - publish an M17 reflector on the local network via
// Bonjour / mDNS / DNS-SD, using the service type "_m17._udp".
//
// TXT record content matches the reflector-entry schema published at
// http://mseven.wonderly.org/mseven/sites.json.gz - MSeven and any other
// M17 client with a compatible parser will pick up the full metadata.
//
// Runs in the foreground until SIGINT/SIGTERM; unregisters cleanly on exit.
//
// Two ways to supply the reflector metadata (either or both):
//   1. Individual --flags (see -h)
//   2. --config path/to/entry.json (single reflectors[] entry from
//      MSeven's sites.json)
//
// Individual flags override values from --config.
//
// Deliberately standalone - no dependency on the mrefd binary or on any
// particular reflector implementation. Reusable for mrefd, urfd, xlxd, etc.

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"

	"github.com/libp2p/zeroconf/v2"
)

// Reflector matches one entry in the MSeven sites.json "reflectors" array.
// JSON tag names are exact so a downloaded entry deserializes byte-for-byte.
type Reflector struct {
	Designator     string   `json:"designator,omitempty"`
	Name           string   `json:"name,omitempty"`
	Slug           string   `json:"slug,omitempty"`
	URL            string   `json:"url,omitempty"`
	DNS            string   `json:"dns,omitempty"`
	IPv4           string   `json:"ipv4,omitempty"`
	IPv6           string   `json:"ipv6,omitempty"`
	Port           int      `json:"port,omitempty"`
	Sponsor        string   `json:"sponsor,omitempty"`
	Country        string   `json:"country,omitempty"`
	Description    string   `json:"description,omitempty"`
	Modules        []string `json:"modules,omitempty"`
	Encrypted      []string `json:"encrypted,omitempty"`
	NetworkType    string   `json:"network_type,omitempty"`
	IPSource       string   `json:"ip_source,omitempty"`
}

// --------------------------------------------------------------------------
// TXT record assembly
// --------------------------------------------------------------------------

// Max bytes for a single mDNS TXT record entry (RFC 6763 §6.1).
const txtItemMaxBytes = 255

// Adds "key=value" to the TXT slice. If the key=value pair exceeds the
// per-item byte cap, splits the value across suffixed keys (key0=, key1=,
// key2=, ...) so a client can reassemble.
func appendTXT(txt []string, key, value string) []string {
	if value == "" {
		return txt
	}
	// Skip: key + "=" + value bytes.
	head := key + "="
	if len(head)+len(value) <= txtItemMaxBytes {
		return append(txt, head+value)
	}
	// Split: chunk size = 255 - len("keyN=")
	chunkKeyBase := key
	// Reserve room for up to two-digit suffix in the key. Suffix "99=" is 3.
	chunkSize := txtItemMaxBytes - (len(chunkKeyBase) + 3 + 1) // key + "N=" and one digit slack
	if chunkSize < 1 {
		chunkSize = 1
	}
	i := 0
	for start := 0; start < len(value); start += chunkSize {
		end := start + chunkSize
		if end > len(value) {
			end = len(value)
		}
		txt = append(txt, fmt.Sprintf("%s%d=%s", chunkKeyBase, i, value[start:end]))
		i++
	}
	return txt
}

// Build the TXT record for a reflector. Fields in a stable order so
// packet captures diff cleanly.
func buildTXT(r Reflector) []string {
	var txt []string
	txt = appendTXT(txt, "type", "reflector")
	txt = appendTXT(txt, "designator", r.Designator)
	txt = appendTXT(txt, "slug", r.Slug)
	txt = appendTXT(txt, "name", r.Name)
	txt = appendTXT(txt, "sponsor", r.Sponsor)
	txt = appendTXT(txt, "country", r.Country)
	txt = appendTXT(txt, "url", r.URL)
	txt = appendTXT(txt, "dns", r.DNS)
	txt = appendTXT(txt, "ipv4", r.IPv4)
	txt = appendTXT(txt, "ipv6", r.IPv6)
	if r.Port > 0 {
		txt = appendTXT(txt, "port", strconv.Itoa(r.Port))
	}
	txt = appendTXT(txt, "modules", strings.Join(r.Modules, ""))
	txt = appendTXT(txt, "encrypted", strings.Join(r.Encrypted, ""))
	txt = appendTXT(txt, "network_type", r.NetworkType)
	txt = appendTXT(txt, "ip_source", r.IPSource)
	txt = appendTXT(txt, "description", r.Description)
	return txt
}

// --------------------------------------------------------------------------
// CLI plumbing
// --------------------------------------------------------------------------

// commaSplit returns nil for empty, else the trimmed comma-separated tokens.
func commaSplit(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}

// Applies non-empty CLI flag values on top of a Reflector (typically loaded
// from --config JSON). Empty flag values leave the field untouched.
func overlayCLI(r *Reflector, f *cliFlags) {
	if f.designator != "" {
		r.Designator = f.designator
	}
	if f.name != "" {
		r.Name = f.name
	}
	if f.slug != "" {
		r.Slug = f.slug
	}
	if f.url != "" {
		r.URL = f.url
	}
	if f.dns != "" {
		r.DNS = f.dns
	}
	if f.ipv4 != "" {
		r.IPv4 = f.ipv4
	}
	if f.ipv6 != "" {
		r.IPv6 = f.ipv6
	}
	if f.port != 0 {
		r.Port = f.port
	}
	if f.sponsor != "" {
		r.Sponsor = f.sponsor
	}
	if f.country != "" {
		r.Country = f.country
	}
	if f.description != "" {
		r.Description = f.description
	}
	if mods := commaSplit(f.modules); mods != nil {
		r.Modules = mods
	}
	if enc := commaSplit(f.encrypted); enc != nil {
		r.Encrypted = enc
	}
	if f.networkType != "" {
		r.NetworkType = f.networkType
	}
	if f.ipSource != "" {
		r.IPSource = f.ipSource
	}
}

type cliFlags struct {
	config      string
	designator  string
	name        string
	slug        string
	url         string
	dns         string
	ipv4        string
	ipv6        string
	port        int
	sponsor     string
	country     string
	description string
	modules     string // comma-separated
	encrypted   string // comma-separated
	networkType string
	ipSource    string

	instanceName string
	iface        string
	domain       string
	dryRun       bool
}

func parseFlags() *cliFlags {
	f := &cliFlags{}
	flag.StringVar(&f.config, "config", "", "path to a JSON file with a single MSeven reflectors[] entry")
	flag.StringVar(&f.designator, "designator", "", "reflector short ID, e.g. \"049\"")
	flag.StringVar(&f.name, "name", "", "human-readable name shown in MSeven")
	flag.StringVar(&f.slug, "slug", "", "URL-safe slug, e.g. \"m17-049\"")
	flag.StringVar(&f.url, "url", "", "dashboard URL")
	flag.StringVar(&f.dns, "dns", "", "public DNS name for the reflector")
	flag.StringVar(&f.ipv4, "ipv4", "", "public IPv4 address")
	flag.StringVar(&f.ipv6, "ipv6", "", "public IPv6 address")
	flag.IntVar(&f.port, "port", 0, "UDP port the reflector listens on (default from --config, or 17000)")
	flag.StringVar(&f.sponsor, "sponsor", "", "sponsoring operator/club/organization")
	flag.StringVar(&f.country, "country", "", "ISO 3166-1 alpha-2 country code")
	flag.StringVar(&f.description, "description", "", "free-text description (HTML permitted)")
	flag.StringVar(&f.modules, "modules", "", "comma-separated list of enabled module letters, e.g. \"A,B,C\"")
	flag.StringVar(&f.encrypted, "encrypted", "", "comma-separated modules that permit encrypted streams")
	flag.StringVar(&f.networkType, "network-type", "", "\"hosting\", \"business\", \"residential\", etc.")
	flag.StringVar(&f.ipSource, "ip-source", "", "how the reflector's IP is resolved: \"dns\" or \"static\"")

	flag.StringVar(&f.instanceName, "instance-name", "", "mDNS service instance name (default: slug)")
	flag.StringVar(&f.iface, "iface", "", "network interface to advertise on (default: all)")
	flag.StringVar(&f.domain, "domain", "local.", "DNS-SD domain")
	flag.BoolVar(&f.dryRun, "dry-run", false, "print the mDNS service registration and exit")

	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(),
			"m17-advertise: publish an M17 reflector via Bonjour (_m17._udp)\n\n"+
				"Usage: %s [flags]\n\n"+
				"Reflector metadata may come from --config <file.json> (matching one\n"+
				"reflectors[] entry from MSeven's sites.json) and/or individual flags.\n"+
				"Individual flags override values loaded from --config.\n\n"+
				"Flags:\n", os.Args[0])
		flag.PrintDefaults()
	}
	flag.Parse()
	return f
}

// --------------------------------------------------------------------------
// main
// --------------------------------------------------------------------------

const serviceType = "_m17._udp"

// primaryIPv4 returns the IPv4 address on the interface the kernel would use
// to reach the default gateway. This is what other devices on the LAN can
// actually reach us on, and it's what we want in the TXT record's "ipv4="
// field when the operator hasn't set it explicitly.
//
// Standard trick: open a UDP socket to any global address. UDP being
// connectionless means no packet is sent, but the kernel populates
// LocalAddr with the interface it would have used.
func primaryIPv4() string {
	c, err := net.Dial("udp4", "8.8.8.8:80")
	if err != nil {
		return ""
	}
	defer c.Close()
	if a, ok := c.LocalAddr().(*net.UDPAddr); ok {
		return a.IP.String()
	}
	return ""
}

func primaryIPv6() string {
	c, err := net.Dial("udp6", "[2001:4860:4860::8888]:80")
	if err != nil {
		return ""
	}
	defer c.Close()
	if a, ok := c.LocalAddr().(*net.UDPAddr); ok {
		return a.IP.String()
	}
	return ""
}

// collectLocalIPs returns IP addresses suitable for publishing in mDNS so
// that other devices on the LAN can actually reach this host. Excludes:
//   - loopback (127.0.0.1, ::1)
//   - IPv6 link-local (fe80::/10) - those require zone IDs and don't work
//     across subnets or when quoted back by a client that doesn't share our
//     interface index
//   - unspecified (0.0.0.0, ::)
//
// If `ifaces` is empty, walks all up interfaces; else walks only those.
func collectLocalIPs(ifaces []net.Interface) ([]string, error) {
	var candidates []net.Interface
	if len(ifaces) > 0 {
		candidates = ifaces
	} else {
		all, err := net.Interfaces()
		if err != nil {
			return nil, fmt.Errorf("list interfaces: %w", err)
		}
		for _, i := range all {
			if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
				continue
			}
			candidates = append(candidates, i)
		}
	}

	var ips []string
	for _, iface := range candidates {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ip, _, err := net.ParseCIDR(a.String())
			if err != nil {
				continue
			}
			if ip.IsLoopback() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() {
				continue
			}
			ips = append(ips, ip.String())
		}
	}
	return ips, nil
}

func loadReflectorConfig(path string) (Reflector, error) {
	var r Reflector
	if path == "" {
		return r, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return r, fmt.Errorf("read config: %w", err)
	}
	if err := json.Unmarshal(b, &r); err != nil {
		return r, fmt.Errorf("parse config JSON: %w", err)
	}
	return r, nil
}

func run() error {
	f := parseFlags()

	r, err := loadReflectorConfig(f.config)
	if err != nil {
		return err
	}
	overlayCLI(&r, f)

	if r.Port == 0 {
		r.Port = 17000
	}

	// If the operator didn't set ipv4/ipv6 explicitly (via --ipv4/--ipv6 or
	// in --config JSON), fill them from the primary interface - the one
	// with the default route, which is what other devices on the LAN can
	// actually reach.
	if r.IPv4 == "" {
		if ip := primaryIPv4(); ip != "" {
			r.IPv4 = ip
			fmt.Fprintf(os.Stderr, "m17-advertise: auto-detected primary IPv4: %s\n", ip)
		}
	}
	if r.IPv6 == "" {
		if ip := primaryIPv6(); ip != "" {
			r.IPv6 = ip
			fmt.Fprintf(os.Stderr, "m17-advertise: auto-detected primary IPv6: %s\n", ip)
		}
	}

	// Instance name: user's override wins, else the slug, else the
	// designator, else the name, else give up.
	instance := f.instanceName
	if instance == "" {
		instance = r.Slug
	}
	if instance == "" {
		instance = r.Designator
	}
	if instance == "" {
		instance = r.Name
	}
	if instance == "" {
		return fmt.Errorf("no --instance-name and reflector has no slug/designator/name to derive one")
	}

	txt := buildTXT(r)

	fmt.Fprintf(os.Stderr, "m17-advertise: publishing %q on %s port %d\n",
		instance, serviceType, r.Port)
	for _, kv := range txt {
		fmt.Fprintf(os.Stderr, "  TXT: %s\n", kv)
	}
	if f.dryRun {
		fmt.Fprintln(os.Stderr, "m17-advertise: --dry-run; not publishing.")
		return nil
	}

	var ifaces []net.Interface
	if f.iface != "" {
		iface, err := net.InterfaceByName(f.iface)
		if err != nil {
			return fmt.Errorf("iface %q: %w", f.iface, err)
		}
		ifaces = []net.Interface{*iface}
	}

	// Use RegisterProxy with an explicit hostname + IP list so we don't get
	// a doubled ".local.local." SRV target when the system hostname is
	// already "hostname.local" (typical on macOS, and what caused MSeven to
	// report the address as "@192.168.1.40%en0"). Strip any trailing
	// ".local" from os.Hostname() so the domain appends exactly once.
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "m17-advertise"
	}
	host = strings.TrimSuffix(host, ".")
	host = strings.TrimSuffix(host, ".local")

	ips, err := collectLocalIPs(ifaces)
	if err != nil {
		return err
	}
	if len(ips) == 0 {
		return fmt.Errorf("no usable non-loopback IPs found to publish")
	}
	fmt.Fprintf(os.Stderr, "m17-advertise: SRV target=%s.%s addresses=%v\n",
		host, strings.TrimSuffix(f.domain, "."), ips)

	server, err := zeroconf.RegisterProxy(
		instance,
		serviceType,
		f.domain,
		r.Port,
		host,
		ips,
		txt,
		ifaces,
	)
	if err != nil {
		return fmt.Errorf("zeroconf.RegisterProxy: %w", err)
	}

	// Wait for signal, then shut down cleanly.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		fmt.Fprintln(os.Stderr, "m17-advertise: shutting down.")
		cancel()
	}()
	<-ctx.Done()
	server.Shutdown()
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "m17-advertise: %v\n", err)
		os.Exit(1)
	}
}
