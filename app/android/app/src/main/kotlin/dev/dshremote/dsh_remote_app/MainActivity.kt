package dev.dshremote.dsh_remote_app

// D-056 修正：local_auth 的系统生物识别弹窗是 Fragment API，宿主必须是
// FlutterFragmentActivity。默认模板的 FlutterActivity 会让 canCheckBiometrics
// 在有指纹的设备上也返回不可用（真机实测：小米有指纹却走 D-061 降级）。
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
