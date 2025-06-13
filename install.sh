#!/bin/bash

install_path="/usr/local/bin/site"
run_cmd="site"

echo "正在下載腳本..."
wget -qO "$install_path" https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/ng.sh || {
  echo "下載失敗，請檢查網址或網路狀態。"
  exit 1
}

chmod +x "$install_path"


echo
echo "腳本已成功安裝！"
echo "請輸入 '$run_cmd' 啟動面板。"

read -n 1 -s -r -p "按任意鍵立即啟動..." key
echo
"site"
