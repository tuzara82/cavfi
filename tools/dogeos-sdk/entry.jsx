// CavFi ↔ DogeOS SDK bridge. Built into site/dogeos.js (+ dogeos.css) and loaded only when someone picks
// "Email, Google or X" in Connect wallet. Exposes window.CavDoge.connect() → an EIP-1193 provider that the
// rest of the site (ethers v5 Web3Provider) uses exactly like MetaMask.
import React, { useEffect, useRef } from "react";
import { createRoot } from "react-dom/client";
import { WalletConnectProvider, useWalletConnect, useAccount, ChainTypeEnum } from "@dogeos/dogeos-sdk";
import "@dogeos/dogeos-sdk/style.css";

const CHAIN = {
  id: 6281971,
  name: "DogeOS Chikyū Testnet",
  nativeCurrency: { name: "DOGE", symbol: "DOGE", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.dogeos.com/"] } },
  blockExplorers: { default: { name: "DogeOS L2Scan", url: "https://dogeos-testnet.l2scan.co" } },
  testnet: true,
};

// A small EIP-1193 wrapper: request() goes to the SDK's current provider; events are re-emitted from SDK state.
function makeProvider() {
  const ls = {};
  const p = {
    isCavDoge: true,
    cur: null,
    request: async (args) => {
      if (!p.cur) throw Object.assign(new Error("DogeOS wallet is not connected."), { code: 4100 });
      if (args && args.method === "wallet_switchEthereumChain") {   // the SDK switches chains itself
        await p.switchTo();
        return null;
      }
      if (args && args.method === "wallet_addEthereumChain") return null;
      return p.cur.request(args);
    },
    on: (e, f) => { (ls[e] ||= []).push(f); return p; },
    removeListener: (e, f) => { ls[e] = (ls[e] || []).filter((x) => x !== f); return p; },
    emit: (e, v) => (ls[e] || []).forEach((f) => { try { f(v); } catch (_) {} }),
    disconnect: async () => {},
    switchTo: async () => {},
  };
  return p;
}

const P = makeProvider();
let api = null, pending = null;

function Bridge() {
  const wc = useWalletConnect();
  const acc = useAccount();
  const last = useRef({ addr: "", chain: "" });
  api = { wc, acc };
  P.disconnect = () => wc.disconnect();
  P.switchTo = async () => { await acc.switchChain({ chainType: ChainTypeEnum.EVM, chainInfo: CHAIN }); };
  useEffect(() => {
    const evm = acc.chainType === "evm" || acc.chainType === ChainTypeEnum.EVM;
    const ok = wc.isConnected && acc.address && acc.currentProvider && evm;
    P.cur = ok ? acc.currentProvider : null;
    const addr = ok ? acc.address : "";
    if (addr !== last.current.addr) {
      const was = last.current.addr; last.current.addr = addr;
      if (addr) {
        if (pending) { const r = pending; pending = null; r.ok(P); }
        else if (was) P.emit("accountsChanged", [addr]);
      } else if (was) { P.emit("accountsChanged", []); P.emit("disconnect", {}); }
    }
    const ch = ok && acc.chainId ? String(acc.chainId) : "";
    if (ch && ch !== last.current.chain) {
      const first = !last.current.chain; last.current.chain = ch;
      const hex = /^0x/.test(ch) ? ch : "0x" + Number(ch.replace(/^.*:/, "")).toString(16);
      if (!first) P.emit("chainChanged", hex);
    }
  });
  useEffect(() => {   // the modal was closed without connecting
    if (!wc.isOpenModal && pending && !wc.isConnecting && !(wc.isConnected && acc.address)) {
      const t = setTimeout(() => { if (pending && !wc.isOpenModal && !(wc.isConnected && acc.address)) { const r = pending; pending = null; r.bad(Object.assign(new Error("closed"), { code: 4001 })); } }, 800);
      return () => clearTimeout(t);
    }
  }, [wc.isOpenModal, wc.isConnecting, wc.isConnected, acc.address]);
  return null;
}

let mounted = null;
function mount(cfg) {
  if (mounted) return mounted;
  const host = document.createElement("div");
  host.id = "cavdoge-root";
  document.body.appendChild(host);
  const config = {
    clientId: cfg.clientId,
    defaultConnectChain: ChainTypeEnum.EVM,
    chains: { evm: [CHAIN] },
    walletConnectProjectId: cfg.walletConnectProjectId || "",
    metadata: { name: "CavFi", description: "DeFi hub on DogeOS testnet", url: location.origin, icons: [location.origin + "/icon-192.png"] },
  };
  createRoot(host).render(<WalletConnectProvider config={config}><Bridge /></WalletConnectProvider>);
  mounted = new Promise((ok) => { const t = setInterval(() => { if (api) { clearInterval(t); ok(); } }, 50); });
  return mounted;
}

window.CavDoge = {
  provider: P,
  // Opens the DogeOS sign-in (email, Google, X, MyDoge and other wallets) and resolves with the provider.
  async connect(cfg) {
    await mount(cfg);
    if (P.cur && api.acc.address) return P;
    const res = new Promise((ok, bad) => { pending = { ok, bad }; });
    api.wc.openModal();
    return res;
  },
  // Restores a session from an earlier visit without opening anything. Resolves with the provider or null.
  async restore(cfg, waitMs) {
    await mount(cfg);
    const t0 = Date.now();
    while (Date.now() - t0 < (waitMs || 6000)) { if (P.cur && api.acc.address) return P; await new Promise((r) => setTimeout(r, 200)); }
    return null;
  },
  async ensureChain() { if (P.cur && api && String(api.acc.chainId || "").replace(/^.*:/, "") !== "6281971") await P.switchTo(); },
  open() { if (api) api.wc.openModal(); },
  async disconnect() { if (api) await api.wc.disconnect(); },
};
