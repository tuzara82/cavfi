// CavFi Markets by hand (the owner key): your own questions and disputed results.
//   node market.mjs list
//   node market.mjs create dogeos "Will DogeOS publish Chapter 6 by Nov 22?" "Yes,No" 2026-11-21T18:00Z 2026-11-22T20:00Z "YES if @DogeOS posts Chapter 6 of The Grand Heist on X before Nov 22 20:00 UTC."
//   node market.mjs propose <id> <outcome number from 0, or void> "<where to check it>"
//   node market.mjs rule <id> <outcome number from 0, or void>      (a disputed market)
//   node market.mjs cancel <id>                                      (before betting closes: full refund)
// The key comes from $env:PRIVATE_KEY (see the README for the hidden prompt). Nothing is sent for "list".
import { ethers } from 'ethers';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const A = JSON.parse(fs.readFileSync(path.join(HERE, '..', 'site', 'addresses.json'), 'utf8'));
if (!A.markets) { console.error('No "markets" in site/addresses.json: deploy CavFi Markets first.'); process.exit(1); }
const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL || 'https://rpc.testnet.dogeos.com');
const ABI = [
  'function create(string category, string question, string[] outcomes, string rules, uint64 closeAt, uint64 resolveAt) returns (uint256)',
  'function propose(uint256 id, uint8 outcome, string evidence)', 'function rule(uint256 id, uint8 outcome)', 'function cancel(uint256 id)',
  'function page(uint256 start, uint256 n) view returns (uint256[] ids, tuple(string question, string category, string rules, string[] outcomes, uint64 closeAt, uint64 resolveAt, uint8 state, uint8 proposed, uint8 winner, uint64 proposedAt, string evidence, address disputer, uint256 total)[] items, uint256[][] pool)',
  'event Created(uint256 indexed id, string category, string question, string[] outcomes, uint64 closeAt, uint64 resolveAt)'];
const ST = ['None', 'Open', 'Proposed', 'Disputed', 'Resolved', 'Refund'];
const [cmd, ...args] = process.argv.slice(2);
const ts = s => { const t = Math.floor(Date.parse(s) / 1000); if (!t) throw new Error('bad time: ' + s + ' (use e.g. 2026-11-21T18:00Z)'); return t; };
const out = o => (o === 'void' ? 255 : Number(o));
async function signer(){
  const pk = process.env.PRIVATE_KEY; if (!pk) throw new Error('Set $env:PRIVATE_KEY first (hidden prompt, see README).');
  return new ethers.Wallet(pk.startsWith('0x') ? pk : '0x' + pk, provider);
}
async function main(){
  if (cmd === 'list' || !cmd){
    const c = new ethers.Contract(A.markets, ABI, provider), [ids, items, pool] = await c.page(0, 40);
    items.forEach((m, i) => {
      const p = pool[i].map(x => Number(ethers.utils.formatEther(x)));
      console.log(`#${ids[i]} [${m.category}] ${m.question}  ·  ${ST[m.state]}${m.state >= 2 ? ' (' + (m.proposed === 255 ? 'void' : m.outcomes[m.proposed]) + ')' : ''}`);
      console.log('    ' + m.outcomes.map((o, j) => `${j}: ${o} ${p[j].toLocaleString()} KingS`).join(' | ') + `  ·  closes ${new Date(Number(m.closeAt) * 1000).toISOString()}`);
    });
    return;
  }
  const w = await signer(), c = new ethers.Contract(A.markets, ABI, w);
  let tx;
  if (cmd === 'create'){
    const [cat, q, outs, close, resolve, rules] = args;
    tx = await c.create(cat, q, outs.split(',').map(x => x.trim()), rules || '', ts(close), ts(resolve));
  } else if (cmd === 'propose') tx = await c.propose(Number(args[0]), out(args[1]), args[2] || '');
  else if (cmd === 'rule') tx = await c.rule(Number(args[0]), out(args[1]));
  else if (cmd === 'cancel') tx = await c.cancel(Number(args[0]));
  else throw new Error('unknown command ' + cmd);
  console.log('sent', tx.hash);
  const rc = await tx.wait();
  const ev = rc.logs.map(l => { try{ return c.interface.parseLog(l); }catch(e){ return null; } }).find(e => e && e.name === 'Created');
  console.log(rc.status === 1 ? 'done' + (ev ? `: market #${ev.args.id}` : '') : 'REVERTED');
}
main().catch(e => { console.error(e.reason || e.message); process.exit(1); });
