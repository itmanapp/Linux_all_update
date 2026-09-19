# Linux_all_update

Linux 系統更新腳本。一鍵完成套件庫重新整理、系統升級與 Flatpak 更新，並在需要時提醒你重新開機。

## 腳本一覽

| 檔案 | 適用系統 | 套件管理 | Flatpak |
|---|---|---|---|
| `ubuntu_all_update.sh` | Ubuntu / Debian 系 | `apt` + `snap` | ✅ |
| `suse_all_update.sh` | openSUSE Leap／Tumbleweed／SLE | `zypper` | ✅ |

## 使用方式

```bash
chmod +x ubuntu_all_update.sh   # 或 suse_all_update.sh
./ubuntu_all_update.sh
```

**請不要用 `sudo ./ubuntu_all_update.sh` 執行。** 腳本會在需要的步驟自行呼叫 `sudo`；以 root 身分執行會讓 `$HOME` 變成 `/root`，導致失敗 log 寫到錯誤位置，Flatpak 的使用者層級更新也會失效。腳本開頭有檢查，會直接拒絕執行。

## 腳本會做什麼

1. 檢查 sudo 權限，失敗就中止
2. 檢查套件管理員是否被其他程序鎖住（背景更新、YaST／PackageKit），必要時等待
3. 重新整理套件庫
   - Ubuntu：`apt update`
   - openSUSE：`zypper refresh`
4. 系統升級
   - Ubuntu：`apt upgrade`（不會為了升級而移除套件）
   - openSUSE Leap／SLE：`zypper update`
   - openSUSE Tumbleweed／Slowroll：`zypper dup`（滾動版本需完整升級）
5. 更新 Flatpak（若已安裝），保留即時下載進度與速率
6. 更新 Snap（僅 Ubuntu 版；未安裝則略過）
7. 檢查是否需要重開機、是否有服務需要重啟
8. 列出已不再需要的套件（僅提示，不會自動移除）
9. 升級成功時清理套件快取

## 安全設計

- **不做破壞性動作**：不會自動執行 `apt autoremove`／`zypper rm -u`，只在最後提示你自己決定
- **保留原有設定檔**：Ubuntu 版升級時使用 `--force-confdef --force-confold`，不覆蓋你改過的設定
- **失敗時保留完整 log**：複製到 `~/.local/share/system-update-logs/<時間戳>/`，最多保留最近 10 份；連 Ctrl+C 中斷也會保留
- **不隱藏密碼提示**：sudo 憑證過期時會當著你的面重新詢問，不會把提示寫進 log 讓畫面看起來像當機
- **結束不關視窗**：在終端機中執行時，結尾會等你按 Enter 才關閉

## 注意事項

- 腳本需要在互動式終端機中執行（會用到 `sudo` 密碼提示與結尾的暫停）
- 在管道或排程中執行（例如 `./ubuntu_all_update.sh | tee log`）時，進度動畫與結尾暫停會自動停用，不會卡住
- Ubuntu 版的 `NEEDRESTART_MODE=a` 只有在安裝 `needrestart` 時才有效；腳本啟動時會告訴你目前的狀態
