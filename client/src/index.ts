/**
 * dsh-remote-relay client — library entry.
 *
 * The tunnel client pairs a local dsh engine with a dsh-remote-relay
 * server: it dials the relay's PSK-authenticated `/ws/dsh` WebSocket,
 * registers pairings (minting signed QR / share URLs), and fulfils the
 * relay's http.req / ws.upgrade data-plane frames against the local engine.
 *
 * CLI wrapper: `./cli.js` (`dsh-remote-client` bin). The framework-plugin
 * face (settings card, QR UI, i18n) lives in the dsh harness — this package
 * is the headless core, usable from any Node 22+ process.
 */
export { RemoteTunnelClient } from './tunnel.ts';
export type {
  RemoteRelayConfig,
  RemoteSessionInfo,
  RemoteDeviceInfo,
  TunnelState,
} from './tunnel.ts';
export {
  PRIVILEGED_METHODS_MIRROR,
  REMOTE_HIDDEN_NAV_SECTIONS,
  isPrivilegedMethod,
} from './remote-capability.ts';
