/**
 * zh copy for the dsh remote-control settings card.
 */
export const zh = {
  title: '远程控制（dsh-remote）',
  description: '通过出站 WSS 中继通道，手机扫码即可远程查看与操作本机 dsh。配对 Token 5 分钟有效、一次性；本地可随时一键断开。',
  enable: '开启远程控制（生成二维码）',
  enabling: '开启中…',
  qrHint: '用手机相机扫码打开远程控制页',
  countdown: '有效期剩余',
  disconnect: '断开所有远程连接',
  disconnecting: '断开中…',
  inactive: '当前无远程会话',
}

export type RemoteCardLocaleKey = keyof typeof zh
