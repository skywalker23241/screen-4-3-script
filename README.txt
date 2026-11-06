Windows 桌面分辨率切换工具 (v3, 1920x1440)
==============================================
本工具修改 Windows 主显示器的桌面分辨率，不修改任何游戏配置文件。
支持 Windows 10 / 11（使用系统自带 PowerShell）。

使用方法
1. 将 ZIP 完整解压到一个新文件夹，不要和旧版脚本混在一起。
2. 首次使用，先运行 04-Diagnose.bat，检查能否正确读取主显示器。
3. 运行 03-List-Supported-Modes.bat，确认驱动提供 1920x1440 显示模式。
4. 关闭正在运行的游戏，双击 01-Set-1920x1440.bat。
5. 屏幕正常时，请在 20 秒内输入 Y 确认；按 N 或超时则尝试自动回退。
6. 游戏结束后，双击 02-Restore-Original.bat，恢复原先的分辨率和刷新率。

文件说明
  01-Set-1920x1440.bat       切换到 1920x1440（4:3）
  02-Restore-Original.bat    恢复第一次切换前记录的设置
  03-List-Supported-Modes.bat 查看显示器驱动支持的模式
  04-Diagnose.bat            显示屏幕检测信息，不修改分辨率
  ResolutionSwitch.ps1       核心脚本，请勿与 BAT 分开放置

备份位置（兼容先前版本）
  %LOCALAPPDATA%\ScreenResolutionSwitcher\original-resolution.json
如果此前版本已经创建备份，新脚本会保留原始备份而不覆盖。

注意事项
- 1920x1440 虽然是标准 4:3，但不一定出现在所有显示器/驱动支持列表中。
- 该工具不创建 NVIDIA 自定义分辨率，也不负责游戏内设置。
- 是否拉伸铺满屏幕由显卡/显示器缩放设置决定。
- 该脚本已静态检查，但未在真实 Windows 设备上完成运行测试。
- 如果诊断失败，停止使用并提供 04-Diagnose.bat 的输出。
- 如果黑屏且回退失败，请在 Windows 设置 > 系统 > 显示 中手动恢复。
