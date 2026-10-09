// `flutter drive` 入口（可选）。日常跑真机冒烟用：
//   cd app && flutter test integration_test -d <serial>
// 本文件只为兼容 `flutter drive --driver=test_driver/integration_test.dart
// --test=integration_test/device_smoke_test.dart` 的 CI 形态。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
