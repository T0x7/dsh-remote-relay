package dev.dshremote.dsh_remote_app

// D-056 修正：local_auth 的系统生物识别弹窗是 Fragment API，宿主必须是
// FlutterFragmentActivity。默认模板的 FlutterActivity 会让 canCheckBiometrics
// 在有指纹的设备上也返回不可用（真机实测：小米有指纹却走 D-061 降级）。
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    /**
     * D-113：`FLAG_SECURE` 防截屏 / 防录屏 / 防任务切换器缩略图外泄。
     *
     * 为什么必须有：屏 E（对话）里是**真实业务内容**——会话正文、工具调用、
     * 文件路径、上下文用量。系统截屏键、录屏、以及最近任务里的缩略图都会把
     * 这些留在设备之外，而 App 自己一点感知都没有。应用商店里的远程控制类
     * App 几乎都会加这条。
     *
     * 在 `onCreate` 里设、且**只设不撤**：撤销会让状态栏截图之类的路径重新漏出
     * 内容，而 `onCreate` 早于 Flutter 首帧，也不影响渲染性能。
     *
     * 代价（知情选择）：用户不能再截图反馈界面问题。真机排障走 `adb
     * screencap`（走 ADB 通道，不受 FLAG_SECURE 影响）与 App 内的诊断日志
     * （屏 G），本项目一直靠这两条，不靠用户截图。
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        super.onCreate(savedInstanceState)
    }
}
