  #!/bin/bash

# 檢查是否以root權限運行
if [ "$(id -u)" -ne 0 ]; then
  echo "此腳本需要root權限運行" 
  exit 1
fi


# 顏色定義
RED='\033[0;31m'     # ❌ 錯誤用紅色
GREEN='\033[0;32m'   # ✅ 成功用綠色
YELLOW='\033[1;33m'  # ⚠️ 警告用黃色
CYAN='\033[0;36m'    # ℹ️ 一般提示用青色
RESET='\033[0m'      # 清除顏色


adjust_opcache_settings() {
  local php_var
  php_var=$(check_php_version)
  local system=$1  # 1 表示 Debian/Ubuntu

  local php_ini
  if [ "$system" -eq 1 ]; then
    php_ini="/etc/php/$php_var/fpm/php.ini"
  else
    php_ini=$(php -i | grep "Loaded Configuration File" | awk '{print $5}')
  fi

  if [ ! -f "$php_ini" ]; then
    echo "❌ 無法找到 php.ini，無法調整 opcache 設定。"
    return 1
  fi

  # 檢查並處理 opcache.revalidate_freq
  if grep -qE '^[[:space:]]*opcache\.revalidate_freq[[:space:]]*=' "$php_ini"; then
    # 提取值
    local current_revalidate_freq
    current_revalidate_freq=$(grep -E '^[[:space:]]*opcache\.revalidate_freq[[:space:]]*=' "$php_ini" | \
      awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}')

    if [ "$current_revalidate_freq" = "0" ]; then
      echo "✅ 調整 opcache.revalidate_freq 為 1"
      sed -i 's/^[[:space:]]*opcache\.revalidate_freq[[:space:]]*=.*/opcache.revalidate_freq=1/' "$php_ini"
    else
      echo "ℹ️ opcache.revalidate_freq 值不是 0，無需修改"
    fi
  else
    echo "ℹ️ opcache.revalidate_freq 未在 php.ini 中設定或僅存在註解，跳過修改"
  fi

  # 檢查並處理 opcache.validate_timestamps
  if grep -qE '^[[:space:]]*opcache\.validate_timestamps[[:space:]]*=' "$php_ini"; then
    # 提取值
    local current_validate_timestamps
    current_validate_timestamps=$(grep -E '^[[:space:]]*opcache\.validate_timestamps[[:space:]]*=' "$php_ini" | \
      awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}')

    if [ "$current_validate_timestamps" = "0" ]; then
      echo "✅ 調整 opcache.validate_timestamps 為 2"
      sed -i 's/^[[:space:]]*opcache\.validate_timestamps[[:space:]]*=.*/opcache.validate_timestamps=2/' "$php_ini"
    else
      echo "ℹ️ opcache.validate_timestamps 值不是 0，無需修改"
    fi
  else
    echo "ℹ️ opcache.validate_timestamps 未在 php.ini 中設定或僅存在註解，跳過修改"
  fi

  echo "✅ 檢查完成"
}
# WordPress備份
# 自動偵測站點類型
# 回傳 wp/flarum/unknown

detect_site_type() {
    local web_root="$1"
    if [[ -f "$web_root/wp-config.php" ]]; then
        echo "wp"
    elif [[ -f "$web_root/config.php" && -d "$web_root/vendor/flarum" ]]; then
        echo "flarum"
    else
        echo "unknown"
    fi
}

# 多站型清除備份主函式，$1=wp/flarum，$2=domain，$3=保留份數
backup_site_type_clean() {
    local type="$1"
    local domain="$2"
    local keep_count="$3"
    local backup_dir="/opt/wp_backups/$domain"
    if [[ ! -d "$backup_dir" ]]; then
        echo "❌ 找不到備份目錄：$backup_dir"
        return 1
    fi
    if [[ ! "$keep_count" =~ ^[0-9]+$ ]]; then
        echo "❌ 保留份數需為數字"
        return 1
    fi
    echo "🧹 正在清理 $type 備份，只保留最新 $keep_count 份..."
    ls -1t "$backup_dir"/backup-*.tar.gz 2>/dev/null | tail -n +$((keep_count + 1)) | xargs -r rm -f
    echo "✅ 清理完成。"
}

# 多站型備份主函式，$1=wp/flarum，$2=domain
backup_site_type() {
    local type="$1"
    local domain="$2"
    local web_root="/var/www/$domain"
    local backup_dir="/opt/wp_backups/$domain"
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local backup_file="$backup_dir/backup-$timestamp.tar.gz"
    mkdir -p "$backup_dir"

    if [[ "$type" == "wp" ]]; then
        local wp_config="$web_root/wp-config.php"
        local tmp_sql="$backup_dir/db-$timestamp.sql"
        local mysqldump_cmd=""
        local mysql_root_pass=""
        local db_name=$(awk -F"'" '/DB_NAME/{print $4}' "$wp_config")  

        # 嘗試無密碼登入
        if mysqldump -uroot --no-data mysql >/dev/null 2>&1; then
          mysqldump_cmd="mysqldump -uroot"
        else
          # 嘗試讀取密碼檔
          if [[ -f /etc/mysql-pass.conf ]]; then
            mysql_root_pass=$(cat /etc/mysql-pass.conf)
            if mysqldump -uroot -p"$mysql_root_pass" --no-data mysql >/dev/null 2>&1; then
              mysqldump_cmd="mysqldump -uroot -p$mysql_root_pass"
            fi
          else
            read -s -p "請輸入 MySQL root 密碼：" mysql_root_pass
            echo
            if mysqldump -uroot -p"$mysql_root_pass" --no-data mysql >/dev/null 2>&1; then
              mysqldump_cmd="mysqldump -uroot -p$mysql_root_pass"
            else
              echo "❌ 無法用該密碼登入 MySQL，備份失敗！"
                return 1
            fi
          fi
        fi
        $mysqldump_cmd --single-transaction --routines --triggers --events "$db_name" > "$tmp_sql"
        
        if [[ $? -ne 0 ]]; then
            echo "❌ 資料庫備份失敗！"
            rm -f "$tmp_sql"
            return 1
        fi
        echo "📁 正在打包網站檔案..."
        cp "$tmp_sql" "$web_root/"
        tar -czf "$backup_file" -C "$web_root" .
        rm -f "$web_root/$(basename "$tmp_sql")"
        rm -f "$tmp_sql"
        echo "✅ 備份完成！檔案位置：$backup_file"
    elif [[ "$type" == "flarum" ]]; then
      local config="$web_root/config.php"
      if [[ ! -f "$config" ]]; then
        echo "❌ 找不到 config.php"
        return 1
      fi

      local db_name=$(php -r "\$c = include '$config'; echo \$c['database']['database'] ?? '';")
      local db_user=$(php -r "\$c = include '$config'; echo \$c['database']['username'] ?? '';")
      local db_pass=$(php -r "\$c = include '$config'; echo \$c['database']['password'] ?? '';")

      if [[ -z "$db_name" || -z "$db_user" ]]; then
        echo "❌ 無法讀取 Flarum DB 設定"
        return 1
      fi

      echo "➡️ 正在匯出 Flarum 資料庫 $db_name..."
      local tmp_sql="$backup_dir/db-$timestamp.sql"
      mysqldump -u"$db_user" -p"$db_pass" "$db_name" > "$tmp_sql"
      if [[ $? -ne 0 ]]; then
          echo "❌ 資料庫備份失敗！"
          rm -f "$tmp_sql"
          return 1
      fi

      # ✅ 把 SQL 複製到 web_root 一起打包
      cp "$tmp_sql" "$web_root/"
      echo "📁 正在打包 Flarum 全部檔案..."
      tar -czf "$backup_file" -C "$web_root" .
      rm -f "$web_root/$(basename "$tmp_sql")"
      rm -f "$tmp_sql"
      echo "✅ 備份完成！檔案位置：$backup_file"
    else
        echo "❌ 不支援的站點類型：$type"
        return 1
    fi
}

# 主備份流程，支援多站型，清理多餘備份由自動備份排程一併處理
backup_site() {
    echo "============【 多站點備份精靈 】============"
    read -p "請輸入站點 domain（例如 example.com）： " domain
    [[ -z "$domain" ]] && echo "❌ 未輸入 domain，取消備份。" && return 1

    local web_root="/var/www/$domain"
    local backup_dir="/opt/wp_backups/$domain"
    mkdir -p "$backup_dir"

    local type=$(detect_site_type "$web_root")
    echo "➡️ 偵測到站點類型：$type"

    if [[ "$type" == "unknown" ]]; then
        echo "❌ 不支援的站點類型，取消備份。"
        return 1
    fi

    echo "➡️ 備份模式選擇："
    echo "  [1] 手動備份一次"
    echo "  [2] 設定每日自動備份"
    read -p "請輸入選項 [1-2]： " mode_choice

    if [[ "$mode_choice" == "1" ]]; then
        backup_site_type "$type" "$domain" || return
        echo
        echo "➡️ 是否清理多餘備份？"
        read -p "保留最新幾份備份檔案？（輸入數字或留空跳過）： " keep_count
        if [[ "$keep_count" =~ ^[0-9]+$ ]]; then
            backup_site_type_clean "$type" "$domain" "$keep_count"
        else
            echo "⚠️ 跳過自動清理。"
        fi
    elif [[ "$mode_choice" == "2" ]]; then
        echo "請輸入自動備份的 crontab 時間格式 (如 '0 3 * * *'、'*/6 * * * *' 等)："
        read -p "crontab 時間：" cron_time
        if [[ -z "$cron_time" ]]; then
            echo "❌ 未輸入 crontab 時間，取消設定排程。"
            return 1
        fi
        read -p "保留最新幾份備份檔案？（輸入數字，必填）： " keep_count
        if [[ ! "$keep_count" =~ ^[0-9]+$ ]]; then
            echo "❌ 請輸入有效數字。"
            return 1
        fi
        cron_job="$cron_time bash -c '$(declare -f detect_site_type); $(declare -f backup_site_type); $(declare -f backup_site_type_clean); type=\"$(detect_site_type /var/www/$domain)\"; backup_site_type \"$type\" \"$domain\"; backup_site_type_clean \"$type\" \"$domain\" \"$keep_count\"'"
        (crontab -l 2>/dev/null | grep -v "$domain"; echo "$cron_job") | crontab -
        echo "✅ 已設定自動備份排程（$cron_time），並自動清理多餘備份（只保留最新 $keep_count 份）！"
    else
        echo "❌ 無效選項，取消備份。"
        return 1
    fi
    echo "============ 備份作業結束 ============"
}

backup_cron_remove() {
    echo "============【 移除多站點備份排程 】============"

    # 先讀取所有含有 /var/www 的 crontab 行
    local cron_list
    cron_list=$(crontab -l 2>/dev/null | grep "/var/www")

    if [[ -z "$cron_list" ]]; then
        echo "⚠️ 系統中沒有任何站點備份排程。"
        return 0
    fi

    echo "目前已設定的站點自動備份排程："
    echo
    # 顯示每行，並編號
    local i=1
    local domains=()
    while IFS= read -r line; do
        # 從 crontab 行找出 domain
        domain=$(echo "$line" | grep -oP "/var/www/\K[^ /]+" | head -n1)
        domains+=("$domain")
        echo "  [$i] $domain"
        ((i++))
    done <<< "$cron_list"

    echo
    read -p "請輸入欲移除排程的序號（或留空取消）： " choice

    if [[ -z "$choice" ]]; then
        echo "⚠️ 已取消。"
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#domains[@]} )); then
        echo "❌ 無效的序號。"
        return 1
    fi

    domain_to_remove="${domains[$((choice-1))]}"

    # 過濾掉該 domain 的 crontab 行
    new_crontab=$(crontab -l 2>/dev/null | grep -v "/var/www/$domain_to_remove")

    # 寫回 crontab
    echo "$new_crontab" | crontab -

    echo "✅ 已移除 $domain_to_remove 的備份排程。"
    echo "============ 移除作業結束 ============"
}

#檢查系統版本
check_system(){
  if command -v apt >/dev/null 2>&1; then
    system=1
  elif command -v yum >/dev/null 2>&1; then
    system=2
  elif command -v apk >/dev/null 2>&1; then
    system=3
   else
    echo -e "${RED}不支援的系統。${RESET}" >&2
    exit 1
  fi
}

check_and_start_service() {
  if command -v openresty >/dev/null 2>&1; then
    local service_name=openresty
  elif command -v nginx >/dev/null 2>&1; then
    local service_name=nginx
  fi

  # 用 service 查詢狀態，通常非 0 表示沒啟動或錯誤
  service "$service_name" status >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "服務 $service_name 未啟動，嘗試啟動中..."
    service "$service_name" start
  else
    echo "服務 $service_name 已啟動"
  fi
}

check_web_environment() {
  use_my_app=false
  port_in_use=false

  if [ "$system" = 3 ]; then
    # Alpine: 使用 netstat 或 ss 檢查端口
    if command -v netstat >/dev/null 2>&1; then
      netstat -tln | grep -qE ':(80|443)\s' && port_in_use=true
    elif command -v ss >/dev/null 2>&1; then
      ss -tln | grep -qE ':(80|443)\s' && port_in_use=true
    fi
  else
    # Debian/CentOS 使用 lsof 檢查端口
    if command -v lsof >/dev/null 2>&1; then
      lsof -iTCP:80 -sTCP:LISTEN >/dev/null 2>&1 && port_in_use=true
      lsof -iTCP:443 -sTCP:LISTEN >/dev/null 2>&1 && port_in_use=true
    fi
  fi

  # 有安裝 nginx 或 openresty 即可啟用
  if command -v nginx >/dev/null 2>&1 || command -v openresty >/dev/null 2>&1; then
    use_my_app=true
  fi
}
clean_ssl_session_cache() {
  local files
  local paths=(
    "/etc/nginx/nginx.conf"
    "/usr/local/openresty/nginx/conf/nginx.conf"
  )

  for file in "${paths[@]}"; do
    if [ -f "$file" ]; then
      # 先計算未註解的 ssl_session_cache 行數
      local count_before count_after
      count_before=$(grep -E '^[[:space:]]*ssl_session_cache' "$file" | wc -l)
      # 刪除未註解的 ssl_session_cache 行（前面不能有 # 和任意空白）
      sed -i '/^[[:space:]]*ssl_session_cache[[:space:]]/d' "$file"
      count_after=$(grep -E '^[[:space:]]*ssl_session_cache' "$file" | wc -l)
      if [ "$count_before" -gt "$count_after" ]; then
        echo "🧹 已清除 $file 中的 ssl_session_cache 設定"
      fi
    fi
  done
}



check_cert() {
  local domain="$1"
  local cert_dir="/etc/letsencrypt/live"

  # 計算網域層級
  IFS='.' read -ra domain_parts <<< "$domain"
  local level=${#domain_parts[@]}

  if [ "$level" -gt 6 ]; then
    echo "網域層級過多（$level），請檢查輸入是否正確。"
    return 1
  fi

  # 掃描所有憑證資料夾，逐一分析 SAN
  for dir in "$cert_dir"/*; do
    [ -d "$dir" ] || continue
    local cert_path="$dir/fullchain.pem"

    if [ -f "$cert_path" ]; then
      local san_list=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null | \
        grep -oE 'DNS:[^,]+' | sed 's/DNS://g')

      for san in $san_list; do
        if [[ "$san" == "$domain" ]] || [[ "$san" == "*.${domain#*.}" ]]; then
          echo "$(basename "$dir")"
          return 0
        fi
      done
    fi
  done

  echo "未找到包含 $domain 的有效憑證"
  return 1
}

#檢查nginx
check_nginx_start(){
  if [[ $use_my_app = false && $port_in_use = false ]]; then
    read -p "是否安裝nginx/openresy？（Y/n）" confirm
    confirm=${confirm,,}
    if [[ "$confirm" = y || -z "$confirm" ]]; then
      install_nginx
    else
      echo "已取消安裝。"
      return
    fi
  fi
}

check_web_server(){
  openresty=0
  nginx=0
  if command -v openresty >/dev/null 2>&1; then
    openresty=1
  elif command -v nginx >/dev/null 2>&1; then
    nginx=1
  fi
}

check_http3_support() {
  support_http3=false

  # 找出 nginx 或 openresty 的執行檔
  nginx_bin=""
  if command -v openresty >/dev/null 2>&1; then
    nginx_bin=$(command -v openresty)
  elif command -v nginx >/dev/null 2>&1; then
    nginx_bin=$(command -v nginx)
  fi

  # 沒有 nginx/openresty 就直接 return
  [ -z "$nginx_bin" ] && return

  # 嘗試從版本資訊中看是否支援 http_v3_module
  if "$nginx_bin" -V 2>&1 | grep -q -- '--with-http_v3_module'; then
    support_http3=true
    echo "$support_http3"
    return
  fi
  echo "$support_http3"
}

check_nginx(){
  check_web_environment
  if [[ $use_my_app = false && $port_in_use = true ]]; then
    echo -e "${RED}偵測到您的系統已安裝其他 Web Server，或 80/443 端口已被佔用。${RESET}"
    echo -e "${YELLOW}請手動停止或解除安裝相關服務，例如 apache、Caddy 或其他佔用程式。${RESET}"
    read -n1 -r -p "請處理完畢後再繼續，按任意鍵結束..." _
    return 1
  elif [[ $use_my_app = false && $port_in_use = false ]]; then
    read -p "是否安裝nginx/openresy？（Y/n）" confirm
    confirm=${confirm,,}
    if [[ "$confirm" = y || -z "$confirm" ]]; then
      install_nginx
    else
      echo "已取消安裝。"
      return
    fi
  else
    echo -e "${YELLOW}您已成功安裝，不用重複安裝${RESET}"
    read -p "操作完成，請按任意鍵繼續..." -n1
  fi
}

#檢查需要安裝之軟體
check_app(){
  if ! command -v wget  >/dev/null 2>&1; then
    case $system in
      1)
        apt update
        apt install wget -y
        ;;
      2)
        yum update
        yum install -y wget
        ;;
      3)
        apk update
        apk add wget
        ;;
    esac
  fi
  if ! command -v curl  >/dev/null 2>&1; then
    case $system in
      1)
        apt update
        apt install curl -y
        ;;
      2)
        yum update
        yum install -y curl
        ;;
      3)
        apk update
        apk add curl
        ;;
    esac
  fi
  if ! command -v nano  >/dev/null 2>&1; then
    case $system in
      1)
        apt update
        apt install nano -y
        ;;
      2)
        yum update
        yum install -y nano
        ;;
      3)
        apk update
        apk add nano
        ;;
    esac
  fi
  if ! command -v ss &>/dev/null; then
    case $system in
      1)
        apt update && apt install -y iproute2
        ;;
      2)
        yum install -y iproute2
        ;;
      3)
        apk update && apk add iproute2
        ;;
    esac
  fi
  if ! command -v lsof &>/dev/null; then
    case $system in
      1)
        apt update && apt install -y lsof
        ;;
      2)
        yum install -y lsof
        ;;
    esac
  fi
  if ! command -v jq &>/dev/null; then
    case $system in
      1)
        apt update && apt install -y jq
        ;;
      2)
        yum install -y jq
        ;;
      3)
        apk add jq
        ;;
    esac
  fi
}
check_certbot(){
  if ! command -v certbot >/dev/null 2>&1; then
    echo "檢測certbot未安裝，正在安裝...."
    case $system in 
      1)
        apt update
        apt install -y snapd
        snap install core && snap refresh core
        snap install --classic certbot
        ln -sf /snap/bin/certbot /usr/bin/certbot
        snap set certbot trust-plugin-with-root=ok
        snap install certbot-dns-cloudflare
        ;;
      2)
        yum install -y epel-release
        yum install -y python3-pip gcc libffi-devel python3-devel
        python3 -m pip install --upgrade pip
        python3 -m pip install --upgrade certbot certbot-nginx certbot-dns-cloudflare certbot-dns-gcore --root-user-action=ignore
        ln -sf /usr/local/bin/certbot /usr/bin/certbot
        ;;
      3) 
        apk update
        apk add python3 py3-pip py3-virtualenv gcc musl-dev libffi-dev openssl-dev
        python3 -m venv /opt/certbot-venv
        (
        source /opt/certbot-venv/bin/activate
        python3 -m pip install --upgrade pip
        python3 -m pip install certbot certbot-nginx certbot-dns-cloudflare certbot-dns-gcore
        )
        ln -s /opt/certbot-venv/bin/certbot /usr/local/bin/certbot
        ;;
    esac
  else
    echo "certbot 已安裝"
  fi
}

check_php(){
  if ! command -v php >/dev/null 2>&1; then
    echo "您好，您尚未安裝php，正在為您安裝..."
    php_install
    php_fix
  fi
}

check_flarum_supported_php() {
  local versions
  local valid_versions=()
  local base_url="https://github.com/flarum/installation-packages/raw/main/packages/v1.x"

  case $system in
    1) # Debian/Ubuntu
      versions=$(apt-cache search ^php[0-9.]+$ | grep -oP '^php\K[0-9.]+' | awk -F. '$1 >= 8 {print}' | sort -Vr)
      ;;
    2) # CentOS
      versions=$(yum module list php | grep -E '^php\s+(remi-)?8\.[0-9]+' | awk '{print $2}' | sed 's/remi-//' | sort -Vu | xargs)
      ;;
    3) # Alpine
      versions=$(apk search -x php[0-9]* | grep -oE 'php[0-9]+' | sed 's/php//' | sort -u | awk '{printf "8.%d\n", $1 - 80}' | sort -Vr)
      ;;
  esac

  for ver in $versions; do
    url="$base_url/flarum-v1.x-no-public-dir-php$ver.zip"
    if curl -s -I "$url" | grep -q '^HTTP/.* 302'; then
      valid_versions+=("$ver")
    fi
  done

  if [[ ${#valid_versions[@]} -eq 0 ]]; then
    echo "❌ 沒有任何版本符合 Flarum 安裝包"
    return 1
  fi

  echo "${valid_versions[*]}"
}


create_directories() {
  mkdir -p /home/web/
  mkdir -p /home/web/cert
  mkdir -p /etc/nginx/conf.d/
  mkdir -p /etc/nginx/logs
  touch /etc/nginx/logs/error.log
  touch /etc/nginx/logs/access.log
}
chown_set(){
  local ngx_user=$(get_nginx_run_user)
  case $system in
    1|2)
      mkdir -p /run/php
      chown -R $ngx_user:$ngx_user /run/php
      chmod 755 /run/php
      ;;
    3)
      mkdir -p /run/php
      chown $ngx_user:$ngx_user /run/php
      chmod 755 /run/php
      rc-service php-fpm83 restart
      ;;
  esac
}

check_no_ngx(){
  check_web_environment
  if [[ $use_my_app != true ]]; then
    echo -e "${RED}您好,您現在使用其他web server 無法使用此功能${RESET}"
    read -p "操作完成,請按任意鍵..." -n1
    return 1
  fi
}

check_php_version() {
  case "$system" in
    1)
      if command -v php >/dev/null 2>&1; then
        phpver=$(php -v | head -n1 | grep -oP '\d+\.\d+')
        echo "$phpver" 
      else
        echo "❌ PHP 尚未安裝。" >&2
        return 1
      fi
      ;;
    2) 
      if command -v php >/dev/null 2>&1; then
        phpver=$(php -v | head -n1 | grep -oP '\d+\.\d+')
        echo "$phpver" # ex 8.3
      else
        echo "❌ PHP 尚未安裝。" >&2
        return 1
      fi
      ;;
    3)
      if command -v php >/dev/null 2>&1; then
        local rawver=$(php -v | head -n1 | grep -oE '[0-9]+\.[0-9]+')  # 使用 -E（延伸正規表示式）
        alpver=$(echo "$rawver" | tr -d '.')
        echo "$alpver" #出現83
      else
        echo "❌ PHP 尚未安裝。" >&2
        return 1
      fi
      ;;
    *)
      echo "❌ 不支援的系統。" >&2
      return 1
      ;;
  esac
}

check_php_ext_available() {
  local ext_name="$1"
  local phpver="$2"  # e.g., "8.2"
  local shortver=$(echo "$phpver" | tr -d '.')

  case "$system" in
    1)  # Debian / Ubuntu (APT)
      apt-cache show "php$phpver-$ext_name" &>/dev/null && return 0
      ;;

    2)  # CentOS / RHEL / AlmaLinux / Rocky (YUM + Remi)
      yum --quiet list available "php-$ext_name" &>/dev/null && return 0
      yum --quiet list available "php-pecl-$ext_name" &>/dev/null && return 0
      ;;

    3)  # Alpine (APK)
      apk search "php$shortver-$ext_name" | grep -q "^php$shortver-$ext_name" && return 0
      ;;
  esac

  return 1
}
cf_cert_autogen() {
    key_file="/ssl_ca/.cf_origin.key"
    enc_file="/ssl_ca/.cf_origin.enc"

    echo "===== Cloudflare Origin 憑證自動申請器 ====="
    echo "感謝NS論壇之bananapork提供的cf文檔"

    # 1. 檢查加密檔案
    if [ ! -f "$key_file" ] || [ ! -f "$enc_file" ]; then
        echo "⚠️ 尚未設定帳號資訊，請輸入："
        read -p "Cloudflare 登入信箱: " cf_email
        read -p "Global API Key（將加密儲存）: " -s cf_key
        echo

        mkdir -p "$(dirname "$key_file")"
        head -c 32 /dev/urandom > "$key_file"
        chmod 600 "$key_file"

        echo "$cf_email:$cf_key" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:"$key_file" -out "$enc_file"
        chmod 600 "$enc_file"
        echo "✅ Cloudflare 認證資料已加密儲存"
    fi

    # 2. 解密帳號資訊
    cf_cred=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$key_file" -in "$enc_file")
    cf_email="$(echo "$cf_cred" | cut -d':' -f1)"
    cf_api_key="$(echo "$cf_cred" | cut -d':' -f2)"

    # 3. 讀取用戶輸入的任何子域名
    while true; do
        read -p "請輸入你擁有的主域名（如 xxx.eu.org 或 xxx.com）: " input_domain
        if [[ "$input_domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo "❌ 請輸入正確格式的域名（不可含 http/https/空格）"
        fi
    done

    # 4. 呼叫 Cloudflare API 抓 zone 列表，自動匹配 base domain
    echo "🔍 正在查詢你帳號下的託管根域名..."
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "X-Auth-Email: $cf_email" \
        -H "X-Auth-Key: $cf_api_key" \
        -H "Content-Type: application/json")

    all_zones=$(echo "$response" | jq -r '.result[].name')
    base_domain=""
    for zone in $all_zones; do
        if [[ "$input_domain" == *"$zone" ]]; then
            base_domain="$zone"
            break
        fi
    done

    if [ -z "$base_domain" ]; then
        echo "❌ 找不到與 $input_domain 對應的根域名，請確認該域名是否在你帳號內託管。"
        return 1
    fi

    echo "✅ 偵測成功：對應的根域名為 $base_domain"

    le_dir="/etc/letsencrypt/live/$base_domain"
    mkdir -p "$le_dir"
    cd "$le_dir" || return 1

    openssl req -new -newkey rsa:2048 -nodes \
        -keyout privkey.pem \
        -out domain.csr \
        -subj "/CN=$base_domain"

    csr_content=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' domain.csr)

    echo "\n🔐 發送憑證申請至 Cloudflare API..."
    response=$(curl -s -X POST https://api.cloudflare.com/client/v4/certificates \
      -H "Content-Type: application/json" \
      -H "X-Auth-Email: $cf_email" \
      -H "X-Auth-Key: $cf_api_key" \
      -d "{
        \"hostnames\": [\"$base_domain\", \"*.$base_domain\"],
        \"requested_validity\": 5475,
        \"request_type\": \"origin-rsa\",
        \"csr\": \"$csr_content\"
      }")

    if echo "$response" | grep -q '"success":true'; then
        echo "$response" | jq -r '.result.certificate' > cert.pem
        cat cert.pem > fullchain.pem
        local cert_id=$(echo "$response" | jq -r '.result.id')
        echo "$cert_id" > cf_cert_id.txt
        echo "✅ 成功！憑證已儲存於：$le_dir"
        echo "- cert.pem"
        echo "- fullchain.pem"
        echo "- privkey.pem"
    else
        echo "❌ 憑證申請失敗，錯誤如下："
        echo "$response" | jq
    fi
}

cf_cert_revoke() {
    local input_domain="$1"
    local key_file="/ssl_ca/.cf_origin.key"
    local enc_file="/ssl_ca/.cf_origin.enc"

    echo "===== Cloudflare Origin 憑證吊銷器 ====="

    if [ ! -f "$key_file" ] || [ ! -f "$enc_file" ]; then
        echo "❌ 尚未設定 Cloudflare 認證資料，請先執行申請功能"
        return 1
    fi

    # 解密認證資料
    cf_cred=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$key_file" -in "$enc_file")
    cf_email="$(echo "$cf_cred" | cut -d':' -f1)"
    cf_api_key="$(echo "$cf_cred" | cut -d':' -f2)"

    # 輸入主域名
    if [ -z "$input_domain" ]; then 
      while true; do
          read -p "請輸入你想吊銷憑證的主域名（如 example.com）: " input_domain
          if [[ "$input_domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
              break
          else
              echo "❌ 請輸入正確格式的域名"
          fi
      done
    fi

    le_dir="/etc/letsencrypt/live/$input_domain"
    cert_id_file="$le_dir/cf_cert_id.txt"

    if [ ! -f "$cert_id_file" ]; then
        echo "❌ 找不到本地憑證 ID ($cert_id_file)，無法吊銷"
        return 1
    fi

    certificate_id=$(cat "$cert_id_file")

    read -p "確定要吊銷 Cloudflare Origin 憑證 ID [$certificate_id] 嗎？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        revoke_response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/certificates/$certificate_id" \
          -H "X-Auth-Email: $cf_email" \
          -H "X-Auth-Key: $cf_api_key" \
          -H "Content-Type: application/json")

        if echo "$revoke_response" | grep -q '"success":true'; then
            echo "✅ Cloudflare Origin 憑證已成功吊銷"

            read -p "是否一併刪除本地憑證檔案（cert.pem, fullchain.pem, privkey.pem）？(y/N): " del_local
            if [[ "$del_local" =~ ^[Yy]$ ]]; then
                rm -f "$le_dir/cert.pem" "$le_dir/fullchain.pem" "$le_dir/privkey.pem" "$cert_id_file"
                echo "✅ 已刪除本地檔案"
            fi
        else
            echo "❌ 吊銷失敗，回傳如下："
            echo "$revoke_response" | jq
        fi
    else
        echo "取消吊銷"
    fi
}

change_wp_admin_username() {
  local domain="$1"
  local site_path="/var/www/$domain"

  # 確認 WordPress 路徑
  if [ ! -f "$site_path/wp-config.php" ]; then
    echo "❌ 找不到 WordPress 安裝路徑：$site_path"
    return 1
  fi

  # 取得管理員用戶名列表
  mapfile -t admins < <(wp --allow-root --path="$site_path" user list --role=administrator --field=user_login)

  if [ ${#admins[@]} -eq 0 ]; then
    echo "❌ 沒有找到管理員用戶"
    return 1
  fi

  local selected_admin=""
  if [ ${#admins[@]} -eq 1 ]; then
    selected_admin="${admins[0]}"
    echo "只有一個管理員用戶：$selected_admin"
  else
    echo "請選擇要修改的管理員用戶："
    select admin in "${admins[@]}"; do
      if [ -n "$admin" ]; then
        selected_admin="$admin"
        break
      else
        echo "請輸入有效選項"
      fi
    done
  fi

  read -p "請輸入新的管理員使用者名稱：" new_username
  if [ -z "$new_username" ]; then
    echo "❌ 新用戶名不可為空，取消修改"
    return 1
  fi

  # 確認新用戶名是否已存在
  if wp --allow-root --path="$site_path" user get "$new_username" >/dev/null 2>&1; then
    echo "❌ 新用戶名已存在，請換一個"
    return 1
  fi

  # 用 SQL 方式修改用戶名（因為 wp-cli 沒有直接修改用戶名指令）
  local sql="UPDATE wp_users SET user_login='${new_username}' WHERE user_login='${selected_admin}';"
  wp --allow-root --path="$site_path" db query "$sql"

  echo "✅ 管理員使用者名稱已從 '$selected_admin' 修改為 '$new_username'"
}

change_wp_admin_password() {
  local domain="$1"
  local site_path="/var/www/$domain"
  
  # 確認 WordPress 路徑
  if [ ! -f "$site_path/wp-config.php" ]; then
    echo "❌ 找不到 WordPress 安裝路徑：$site_path"
    return 1
  fi

  # 取得管理員用戶名列表
  mapfile -t admins < <(wp --allow-root --path="$site_path" user list --role=administrator --field=user_login)

  if [ ${#admins[@]} -eq 0 ]; then
    echo "❌ 沒有找到管理員用戶"
    return 1
  fi

  local selected_admin=""
  if [ ${#admins[@]} -eq 1 ]; then
    selected_admin="${admins[0]}"
    echo "只有一個管理員用戶：$selected_admin"
  else
    echo "請選擇要修改密碼的管理員用戶："
    select admin in "${admins[@]}"; do
      if [ -n "$admin" ]; then
        selected_admin="$admin"
        break
      else
        echo "請輸入有效選項"
      fi
    done
  fi

  # 輸入新密碼（隱藏輸入）
  read -s -p "請輸入新的密碼：" new_password
  echo
  if [ -z "$new_password" ]; then
    echo "❌ 密碼不可為空，取消修改"
    return 1
  fi

  read -s -p "請再輸入一次新的密碼以確認：" confirm_password
  echo
  if [ "$new_password" != "$confirm_password" ]; then
    echo "❌ 兩次輸入的密碼不一致，取消修改"
    return 1
  fi

  # 修改密碼
  wp --allow-root --path="$site_path" user update "$selected_admin" --user_pass="$new_password" --skip-email

  if [ $? -eq 0 ]; then
    echo "✅ 管理員 '$selected_admin' 的密碼已更新成功"
  else
    echo "❌ 密碼更新失敗"
    return 1
  fi
}

default(){
  local detect_conf_path=$(detect_conf_path)
  create_directories
  generate_ssl_cert
  case "$system" in
  1|2)
    rm -f $detect_conf_path/default.conf $detect_conf_path/default
    wget -O /etc/nginx/conf.d/default.conf https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/default_system
    rm -f /etc/nginx/nginx.conf
    wget -O /etc/nginx/nginx.conf https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/nginx.conf
    id -u nginx &>/dev/null || useradd -r -s /sbin/nologin -M nginx
    systemctl restart openresty
    ;;
  3)
    mkdir -p /usr/local/share/lua/5.1
    # download lua environment value
    cd /usr/local/share/lua/5.1/
    git clone https://github.com/openresty/lua-resty-core.git resty_core_temp || {
      echo "下載 lua-resty-core 失敗"; return 1;
    }
    cp -r resty_core_temp/lib/resty ./resty
    rm -rf resty_core_temp

    wget -O ./resty/lrucache.lua https://raw.githubusercontent.com/openresty/lua-resty-lrucache/master/lib/resty/lrucache.lua || {
      echo "下載 lrucache 失敗"; return 1;
    }
    # download default
    rm -f $detect_conf_path/default.conf
    rm -f /etc/nginx/nginx.conf
    wget -O /etc/nginx/nginx.conf https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/nginx.conf
    sed -i 's|^#\s*pid\s\+/run/nginx.pid;|pid /run/nginx.pid;|' /etc/nginx/nginx.conf
    wget -O /etc/nginx/conf.d/default.conf https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/default_system
    id -u nginx &>/dev/null || adduser -D -H -s /sbin/nologin nginx
    rc-service nginx restart
    ;;
  esac
}

detect_conf_path() {
  conf_paths=()
  nginx_conf=""

  if command -v openresty >/dev/null 2>&1 ; then
    nginx_conf="/usr/local/openresty/nginx/conf/nginx.conf"
  elif command -v nginx >/dev/null 2>&1; then
    nginx_conf="/etc/nginx/nginx.conf"
  fi

  [ -f "$nginx_conf" ] || { echo "❌ 無法找到 nginx 配置文件" >&2; return 1; }

  include_lines=$(sed -n '/http[[:space:]]*{/,/^}/p' "$nginx_conf" | tr -d '\r' | grep -E 'include[[:space:]]+[^;]*\*[^;]*;')

  while IFS= read -r line; do
    raw_path=$(echo "$line" | sed -E 's/^[[:space:]]*include[[:space:]]+(.+);/\1/')
    raw_path=$(dirname "$raw_path")
    raw_path=$(eval echo "$raw_path")
    [ -z "$raw_path" ] && continue

    resolved_path=$(realpath "$raw_path" 2>/dev/null)
    [ -z "$resolved_path" ] && resolved_path="$raw_path"

    conf_paths+=("$resolved_path")
  done <<< "$include_lines"

  for path in "${conf_paths[@]}"; do
    if ls "$path"/* >/dev/null 2>&1; then
      echo "$path"
      return 0
    fi
  done

  if command -v openresty >/dev/null 2>&1; then
    conf_path="/usr/local/openresty/nginx/conf/conf.d"
  elif command -v nginx >/dev/null 2>&1; then
    conf_path="/etc/nginx/conf.d"
  fi

  mkdir -p "$conf_path"
  echo "$conf_path"
}
detect_sites() {
  local app_type="$1"
  local base_dir="/var/www"

  [ -z "$app_type" ] && {
    echo "請輸入要偵測的應用名稱，例如：WordPress 或 Flarum"
    return 1
  }

  for dir in "$base_dir"/*; do
    [ ! -d "$dir" ] && continue

    case "$app_type" in
      WordPress)
        if [ -f "$dir/wp-config.php" ]; then
          echo "$(basename "$dir")"
        fi
        ;;
      Flarum)
        if [ -f "$dir/flarum" ] || [ -f "$dir/site.php" ] || [ -d "$dir/vendor/flarum" ]; then
          echo "$(basename "$dir")"
        fi
        ;;
    esac
  done
}

detect_sites_menu() {
  local app_type="$1"
  local base_dir="/var/www"
  local sites=()

  [ -z "$app_type" ] && {
    echo "請輸入要偵測的應用名稱，例如：WordPress 或 Flarum" >&2
    return 1
  }

  for dir in "$base_dir"/*; do
    [ ! -d "$dir" ] && continue

    case "$app_type" in
      WordPress)
        [ -f "$dir/wp-config.php" ] && sites+=("$(basename "$dir")")
        ;;
      Flarum)
        [ -f "$dir/flarum" ] || [ -f "$dir/site.php" ] || [ -d "$dir/vendor/flarum" ] && \
          sites+=("$(basename "$dir")")
        ;;
      *)
        echo "暫不支援偵測此應用：$app_type" >&2
        return 1
        ;;
    esac
  done

  if [ ${#sites[@]} -eq 0 ]; then
    echo "未偵測到任何 $app_type 網站" >&2
    return 1
  fi

  if ! [ -t 0 ]; then
    echo "❌ 非交互式環境，無法使用選單" >&2
    return 1
  fi

  echo "請選擇欲操作的 $app_type 網站：" >&2
  select site in "${sites[@]}"; do
    if [ -n "$site" ]; then
      echo "$site"
      return 0
    else
      echo "請輸入有效的編號" >&2
    fi
  done
}

install_wp_plugin_with_search_or_url() {
  local domain="$1"
  local site_path="/var/www/$domain"
  local plugin_dir="$site_path/wp-content/plugins"

  read -p "請輸入插件關鍵字 或 ZIP 下載網址: " input
  [ -z "$input" ] && echo "❌ 未輸入內容" && return 1

  # ---------------------------------------------------
  # 如果是 ZIP 下載網址
  # ---------------------------------------------------
  if [[ "$input" =~ ^https?://.*\.zip$ ]]; then
    echo "🔽 偵測到為 ZIP 插件連結，開始下載..."
    tmp_file="/tmp/plugin_$$.zip"

    if ! wget -qO "$tmp_file" "$input"; then
      echo "❌ 下載失敗"
      return 1
    fi

    if ! unzip -t "$tmp_file" >/dev/null 2>&1; then
      echo "❌ 下載的檔案不是有效的 ZIP 壓縮檔"
      rm -f "$tmp_file"
      return 1
    fi

    unzip -q "$tmp_file" -d "$plugin_dir" || {
      echo "❌ 解壓失敗"
      rm -f "$tmp_file"
      return 1
    }
    rm -f "$tmp_file"
    echo "✅ 插件已解壓至：$plugin_dir"

    plugin_slug=$(ls -1 "$plugin_dir" | head -n 1)
    if [ -n "$plugin_slug" ]; then
      echo "🚀 正在嘗試啟用插件..."
      wp --allow-root --path="$site_path" plugin activate "$plugin_slug" 2>/dev/null \
         && echo "✅ 已啟用插件：$plugin_slug" \
         || echo "⚠️ 無法自動啟用，請手動啟用插件"
    else
      echo "⚠️ 無法偵測插件目錄，請手動啟用插件"
    fi
    return 0
  fi

  # ---------------------------------------------------
  # 插件關鍵字搜尋（使用 JSON 以避免 CSV 問題）
  # ---------------------------------------------------
  echo "🔍 正在搜尋包含 \"$input\" 的插件..."

  mapfile -t plugins < <(
    wp --allow-root --path="$site_path" plugin search "$input" --per-page=10 --format=json | jq -r '.[] | "\(.name)|\(.slug)"'
  )

  if [ ${#plugins[@]} -eq 0 ]; then
    echo "❌ 找不到任何相關插件"
    return 1
  fi

  local options=()
  local slugs=()

  for entry in "${plugins[@]}"; do
    name="${entry%%|*}"
    slug="${entry##*|}"
    [ -n "$slug" ] && options+=("$name (slug: $slug)") && slugs+=("$slug")
  done

  if [ ${#options[@]} -eq 0 ]; then
    echo "❌ 找不到任何有效插件"
    return 1
  fi

  echo "請選擇欲安裝的插件："
  select opt in "${options[@]}"; do
    if [ -n "$opt" ]; then
      idx=$((REPLY - 1))
      slug="${slugs[$idx]}"
      echo "⬇️ 開始安裝插件：$slug"
      wp --allow-root --path="$site_path" plugin install "$slug" --activate
      return
    else
      echo "❌ 無效的選項，請重新選擇"
    fi
  done
}



remove_wp_plugin_with_menu() {
  local domain="$1"
  local site_path="/var/www/$domain"
  local plugin_dir="$site_path/wp-content/plugins"

  echo "🔍 正在偵測已安裝的插件..."

  # 只抓目錄 (真正的 plugins)
  mapfile -t plugin_folders < <(
    find "$plugin_dir" -mindepth 1 -maxdepth 1 -type d -printf "%f\n"
  )

  if [ ${#plugin_folders[@]} -eq 0 ]; then
    echo "✅ 此網站沒有安裝任何插件"
    return 0
  fi

  local options=()
  for folder in "${plugin_folders[@]}"; do
    status=$(wp --allow-root --path="$site_path" plugin get "$folder" --field=status 2>/dev/null)
    if [ -n "$status" ]; then
      options+=("$folder [$status]")
    else
      options+=("$folder [unknown]")
    fi
  done

  echo "請選擇要移除的插件："
  select opt in "${options[@]}"; do
    if [ -n "$opt" ]; then
      slug=$(echo "$opt" | awk '{print $1}')
      echo "🗑 正在移除插件：$slug"
      wp --allow-root --path="$site_path" plugin deactivate "$slug"
      wp --allow-root --path="$site_path" plugin delete "$slug"
      echo "✅ 插件已刪除：$slug"
      return
    else
      echo "❌ 無效的選項，請重新選擇"
    fi
  done
}





deploy_or_remove_theme() {
  local action="$1"           # install or remove
  local domain="$2"           # 網址 (如 aa.com)

  local site_path="/var/www/$domain"
  local wp_theme_dir="$site_path/wp-content/themes"
  local wp_cli="wp --allow-root"

  # 確保 wp-cli 存在
  if ! command -v wp >/dev/null 2>&1; then
    echo "❌ 找不到 wp-cli，可先執行 install_wp_cli"
    return 1
  fi

  # 確保路徑存在
  if [ ! -d "$wp_theme_dir" ]; then
    echo "❌ 找不到 WordPress themes 目錄：$wp_theme_dir"
    return 1
  fi

  case "$action" in
    install)
      read -p "請輸入主題名稱或下載 URL：" theme_input
      if [ -z "$theme_input" ]; then
        echo "❌ 未輸入任何主題名稱或 URL，取消安裝"
        return 1
      fi

      if [[ "$theme_input" =~ ^https?:// ]]; then
        # 是網址，先下載
        tmp_file="/tmp/theme_download.$(date +%s)"
        echo "🌐 正在下載主題：$theme_input"
        curl -L "$theme_input" -o "$tmp_file" || {
          echo "❌ 無法下載 $theme_input"
          return 1
        }

        # 解壓縮
        case "$theme_input" in
          *.zip)
            unzip -q "$tmp_file" -d "$wp_theme_dir" || {
              echo "❌ 解壓縮失敗"
              rm -f "$tmp_file"
              return 1
            }
            ;;
          *.tar.gz|*.tgz)
            tar -xzf "$tmp_file" -C "$wp_theme_dir" || {
              echo "❌ 解壓縮失敗"
              rm -f "$tmp_file"
              return 1
            }
            ;;
          *.tar)
            tar -xf "$tmp_file" -C "$wp_theme_dir" || {
              echo "❌ 解壓縮失敗"
              rm -f "$tmp_file"
              return 1
            }
            ;;
          *)
            echo "❌ 不支援的壓縮格式：$theme_input"
            rm -f "$tmp_file"
            return 1
            ;;
        esac

        echo "✅ 主題已部署到 $wp_theme_dir"
        rm -f "$tmp_file"

      else
        # 非網址 → 當作主題名稱 → wp-cli 搜尋
        echo "🔍 正在搜尋主題：$theme_input"

        mapfile -t themes < <(
          $wp_cli --path="$site_path" theme search "$theme_input" --per-page=10 --format=json \
          | jq -r '.[] | "\(.name)|\(.slug)"'
        )

        if [ ${#themes[@]} -eq 0 ]; then
          echo "❌ 找不到任何與 \"$theme_input\" 相關的主題"
          return 1
        fi

        local options=()
        local slugs=()

        for entry in "${themes[@]}"; do
          name="${entry%%|*}"
          slug="${entry##*|}"
          [ -n "$slug" ] && options+=("$name (slug: $slug)") && slugs+=("$slug")
        done

        echo "請選擇要安裝的主題："
        select opt in "${options[@]}"; do
          if [ -n "$opt" ]; then
            idx=$((REPLY - 1))
            slug="${slugs[$idx]}"
            echo "⚙️  正在安裝主題：$slug"
            $wp_cli --path="$site_path" theme install "$slug" --activate
            echo "✅ 已安裝並啟用主題：$slug"
            return 0
          else
            echo "❌ 無效的選項，請重新選擇"
          fi
        done
      fi
      ;;

    remove)
      echo "🔍 正在偵測已安裝的主題..."

      mapfile -t themes < <(
        $wp_cli --path="$site_path" theme list --status=active,inactive --format=json \
        | jq -r '.[] | "\(.name)|\(.status)|\(.slug)"'
      )

      if [ ${#themes[@]} -eq 0 ]; then
        echo "⚠️ 尚未安裝任何主題"
        return 0
      fi

      local options=()
      local slugs=()

      for theme in "${themes[@]}"; do
        name=$(echo "$theme" | cut -d'|' -f1)
        status=$(echo "$theme" | cut -d'|' -f2)
        slug=$(echo "$theme" | cut -d'|' -f3)

        options+=("$name [$status]")
        slugs+=("$slug")
      done

      echo "請選擇要移除的主題："
      select opt in "${options[@]}"; do
        if [ -n "$opt" ]; then
          idx=$((REPLY - 1))
          slug="${slugs[$idx]}"

          echo "🗑 正在移除主題：$slug"
          $wp_cli --path="$site_path" theme delete "$slug"
          echo "✅ 已移除主題：$slug"
          return 0
        else
          echo "❌ 無效的選項，請重新選擇"
        fi
      done
      ;;

    *)
      echo "❌ 不支援的操作：$action"
      return 1
      ;;
  esac
}


flarum_setup() {
  local php_var=$(check_php_version)
  local supported_php_versions=$(check_flarum_supported_php)
  local max_supported_php=$(echo "$supported_php_versions" | tr ' ' '\n' | sort -V | tail -n1)
  local ngx_user=$(get_nginx_run_user)

  # 判斷 PHP 是否高於支援版本
  if [ "$(printf '%s\n' "$php_var" "$max_supported_php" | sort -V | tail -n1)" != "$php_var" ]; then
    echo "⚠️  您目前使用的 PHP 版本是 $php_var，但 Flarum 僅建議使用到 $max_supported_php。"
    read -p "是否仍要繼續安裝？(y/N)：" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 1
  fi
  # 根據是否支援決定使用哪個 zip 檔
  if echo "$supported_php_versions" | grep -qw "$php_var"; then
    local download_phpver="$php_var"
  else
    echo "⚠️ 您選擇的 PHP 版本不在 Flarum 支援列表，將改為使用 Flarum 支援的最高版本 $max_supported_php 的安裝包。"
    local download_phpver="$max_supported_php"
  fi

  if ! command -v mysql &>/dev/null; then
    echo "MySQL 未安裝，請先安裝 MySQL。"
    return 1
  fi

  if ! command -v composer &>/dev/null; then
    echo "正在安裝 Composer..."
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
  fi

  read -p "請輸入您的Flarum網址（例如 bbs.example.com）：" domain

  # 自動申請 SSL（若不存在）
  check_cert "$domain" || {
    echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
    if ssl_apply "$domain"; then
      echo "申請成功，重新驗證憑證..."
      check_cert "$domain" || {
        echo "申請成功但仍無法驗證憑證，中止建立站點"
        return 1
      }
    else
      echo "SSL 申請失敗，中止建立站點"
      return 1
    fi
  }

  # MySQL 自動登入邏輯
  mysql_cmd="mysql -uroot"
  if ! $mysql_cmd -e ";" &>/dev/null; then
    if [ -f /etc/mysql-pass.conf ]; then
      mysql_root_pass=$(cat /etc/mysql-pass.conf)
      mysql_cmd="mysql -uroot -p$mysql_root_pass"
    else
      read -s -p "請輸入 MySQL root 密碼：" mysql_root_pass
      echo
      mysql_cmd="mysql -uroot -p$mysql_root_pass"
    fi
    if ! $mysql_cmd -e ";" &>/dev/null; then
      echo "無法登入 MySQL，請確認密碼正確。"
      return 1
    fi
  fi

  db_name="flarum_${domain//./_}"
  db_user="${db_name}_user"
  db_pass=$(openssl rand -hex 12)

  $mysql_cmd -e "CREATE DATABASE $db_name DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  $mysql_cmd -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
  $mysql_cmd -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
  $mysql_cmd -e "FLUSH PRIVILEGES;"

  # 下載 Flarum
  mkdir -p /var/www/$domain
  wget "https://github.com/flarum/installation-packages/raw/main/packages/v1.x/flarum-v1.x-no-public-dir-php$download_phpver.zip" -O /tmp/flarum.zip
  mkdir -p /tmp/flarum
  unzip /tmp/flarum.zip -d /tmp/flarum
  cp -a /tmp/flarum/. /var/www/$domain/
  rm -rf /tmp/flarum.zip /tmp/flarum
  cd "/var/www/$domain"

  export COMPOSER_ALLOW_SUPERUSER=1
  composer install --no-dev --no-interaction
  composer require --no-interaction flarum-lang/chinese-traditional
  composer require --no-interaction flarum-lang/chinese-simplified
  php flarum cache:clear
  echo "已安裝繁體與簡體中文語系，可至 Flarum 後台 Extensions 啟用。"

  chown -R $ngx_user:$ngx_user "/var/www/$domain"
  setup_site "$domain" flarum

  adjust_opcache_settings
  
  case $system in
  1)
    service php$php_var-fpm restart
    ;;
  2)
    service php-fpm restart
    ;;
  3)
    service php$php_var-fpm restart
    ;;
  esac
  
  echo "===== Flarum 資訊 ====="
  echo "網址：https://$domain"
  echo "資料庫名稱：$db_name"
  echo "資料庫用戶：$db_user"
  echo "資料庫密碼：$db_pass"
  echo "請在安裝介面輸入以上資訊完成安裝。"
  echo "======================="
}

flarum_extensions() {
  read -p "請輸入 Flarum 網址（例如 bbs.example.com）：" flarum_domain

  site_path="/var/www/$flarum_domain"
  if [ ! -f "$site_path/config.php" ]; then
    echo "此站點並非 Flarum 網站（缺少 config.php）。"
    return 1
  fi

  echo "已偵測為 Flarum 網站：$flarum_domain"
  echo "選擇操作："
  echo "1) 安裝擴展"
  echo "2) 移除擴展"
  read -p "請選擇操作（預設 1）：" action
  action="${action:-1}"

  read -p "請輸入擴展套件名稱（例如 flarum-lang/chinese-traditional）：" ext_name

  cd "$site_path"
  
  if [ "$action" = "1" ]; then
    export COMPOSER_ALLOW_SUPERUSER=1
    composer require --no-interaction "$ext_name"
    php flarum cache:clear
    echo "擴展已安裝並清除快取。請至後台啟用擴展。"
  elif [ "$action" = "2" ]; then
    export COMPOSER_ALLOW_SUPERUSER=1
    composer remove --no-interaction "$ext_name"
    php flarum cache:clear
    echo "擴展已移除並清除快取。"
  else
    echo "無效選項。"
  fi
}


generate_ssl_cert(){
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout /home/web/cert/default_server.key \
  -out /home/web/cert/default_server.crt \
  -days 5475 \
  -subj "/C=US/ST=State/L=City/O=Organization/OU=Organizational Unit/CN=Common Name"
}

get_nginx_run_user() {
  local nginx_conf=""
  
  # 偵測 nginx.conf 路徑（簡化版）
  if [ -f /etc/nginx/nginx.conf ]; then
    nginx_conf="/etc/nginx/nginx.conf"
  elif [ -f /usr/local/openresty/nginx/conf/nginx.conf ]; then
    nginx_conf="/usr/local/openresty/nginx/conf/nginx.conf"
  else
    echo "nobody"
    return 1
  fi

  # 讀取 user 行，抓第一個 user 名稱，去掉分號
  local user
  user=$(grep -E '^\s*user\s+' "$nginx_conf" | head -1 | awk '{print $2}' | sed 's/;//')

  # 如果沒找到 user，預設 nobody
  if [ -z "$user" ]; then
    echo "nobody"
  else
    echo "$user"
  fi
}


html_sites(){
  local ngx_user=$(get_nginx_run_user)
  read -p "請輸入網址:" domain
  check_cert "$domain" || {
    echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
    if ssl_apply "$domain"; then
      echo "申請成功，重新驗證憑證..."
        check_cert "$domain" || {
          echo "申請成功但仍無法驗證憑證，中止建立站點"
          return 1
        }
    else
      echo "SSL 申請失敗，中止建立站點"
      return 1
    fi
  }
  mkdir -p /var/www/$domain
  local confirm
  read -p "是否自訂html?(Y/n)" confirm
  confirm=${confirm,,}
  if [[ $confirm == y || $confirm == "" ]]; then
    nano /var/www/$domain/index.html
  else
    echo "<h1>歡迎來到 $domain</h1>" > /var/www/$domain/index.html
  fi
  chown -R $ngx_user:$ngx_user /var/www/$domain
  setup_site "$domain" html
  echo "已建立 $domain 之html站點。"
}
httpguard_setup(){
  check_php
  case $system in
  1|2)
    if ! command -v openresty &>/dev/null; then
      echo -e "${RED}未偵測到 openresty 指令${RESET}"
      read -p "操作完成，請按任意鍵繼續..." -n1
      return 1
    fi
    if ! openresty -V 2>&1 | grep -iq lua; then
      echo -e "${RED}您的 OpenResty 不支援 Lua 模組，無法使用 HttpGuard。${RESET}"
      read -p "操作完成，請按任意鍵繼續..." -n1
      
      return 1
    fi
    local ngx_conf="/usr/local/openresty/nginx/conf/nginx.conf"
    local guard_dir="/usr/local/openresty/nginx/conf/HttpGuard"
    ;;
  3)
    if ! command -v nginx &>/dev/null; then
      echo -e "${RED}未偵測到 nginx 指令${RESET}"
      read -p "操作完成，請按任意鍵繼續..." -n1
      return 1
    fi
    if ! nginx -V 2>&1 | grep -iq lua; then
      echo -e "${RED}您的 Nginx 不支援 Lua 模組，無法使用 HttpGuard。${RESET}"
      read -p "操作完成，請按任意鍵繼續..." -n1
      return 1
    fi
    local ngx_conf="/etc/nginx/nginx.conf"
    local guard_dir="/etc/nginx/HttpGuard"
    ;;
  esac
  if [ -d "$guard_dir" ]; then
    echo "HttpGuard 已安裝，進入管理選單..."
    menu_httpguard
    return 0
  fi
  local marker="HttpGuard/init.lua"

  # === 若尚未安裝則執行安裝 ===
  echo "下載 HttpGuard..."
  
  case $system in
  1|2)
    local HttpGuard_download_path="/usr/local/openresty/nginx/conf/HttpGuard.zip"
    local http_path="/usr/local/openresty/nginx/conf/HttpGuard"
    ;;
  3)
    local HttpGuard_download_path="/etc/nginx/HttpGuard.zip"
    local http_path="/etc/nginx/HttpGuard"
    ;;
  esac
  wget -O $HttpGuard_download_path https://files.gebu8f.com/site/HttpGuard.zip || {
    echo "下載失敗"
    return 1
  }

  unzip -o "$HttpGuard_download_path" -d /etc/nginx
  if [ $system = 3 ]; then
    sed -i "s|^baseDir *=.*|baseDir = '/etc/nginx/HttpGuard/'|" /etc/nginx/HttpGuard/config.lua
    local ss_path=$(command -v ss 2>/dev/null)
    if [ -n "$ss_path" ]; then
      sed -i "s|ssCommand *= *\"[^\"]*\"|ssCommand = \"$ss_path\"|" /etc/nginx/HttpGuard/config.lua
    fi
  fi
  rm $HttpGuard_download_path
  echo "正在生成動態配置文件..."
  cd $http_path/captcha/
  php getImg.php
  
  chown -R nginx:nginx $http_path
  if [[ $system == 1 || $system == 2 ]]; then
    sed -i '/http {/a \
      lua_package_path "/usr/local/openresty/lualib/?.lua;/usr/local/openresty/nginx/conf/HttpGuard/?.lua;;";\n\
      lua_package_cpath "/usr/local/openresty/lualib/?.so;;";\n\
      lua_shared_dict guard_dict 100m;\n\
      lua_shared_dict dict_captcha 128m;\n\
      init_by_lua_file /usr/local/openresty/nginx/conf/HttpGuard/init.lua;\n\
      access_by_lua_file /usr/local/openresty/nginx/conf/HttpGuard/runtime.lua;\n\
      lua_max_running_timers 1;' "$ngx_conf"
    else
      sed -i '/http {/a \
        lua_package_path "/usr/local/share/lua/5.1/?.lua;/etc/nginx/HttpGuard/?.lua;;";\n\
        lua_package_cpath "/usr/local/lib/lua/5.1/?.so;;";\n\
        lua_shared_dict guard_dict 100m;\n\
        lua_shared_dict dict_captcha 128m;\n\
        init_by_lua_file /etc/nginx/HttpGuard/init.lua;\n\
        access_by_lua_file /etc/nginx/HttpGuard/runtime.lua;\n\
        lua_max_running_timers 1;' /etc/nginx/nginx.conf
    fi
      
  if nginx -t; then
    restart_nginx_openresty
    echo "HttpGuard 安裝完成"
    menu_httpguard
  else
    echo "安裝失敗.."
    return 1
  fi
}

install_nginx(){
  echo "未偵測到 Nginx 或 OpenResty，執行安裝..."
  case "$system" in
  1)
    apt update
    apt install -y curl gnupg2 ca-certificates lsb-release
        local os=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
    curl -s https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/openresty.gpg
    if [[ $os == "debian" ]]; then
          echo "deb http://openresty.org/package/debian $(lsb_release -sc) openresty" | tee /etc/apt/sources.list.d/openresty.list
    elif [[ $os == "ubuntu" ]]; then
      echo "deb http://openresty.org/package/ubuntu $(lsb_release -sc) openresty" | tee /etc/apt/sources.list.d/openresty.list
        fi
    apt update
    apt install openresty -y
    rm -rf /etc/nginx
    ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
    ln -sf /usr/local/openresty/nginx/conf /etc/nginx
    mkdir -p /etc/nginx/conf.d
    default
    ;;
  2)
    yum update
    yum install -y yum-utils
    yum-config-manager --add-repo https://openresty.org/package/centos/openresty.repo
    yum update
    yum install -y openresty --nogpgcheck
    rm -rf /etc/nginx
    ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
    ln -sf /usr/local/openresty/nginx/conf /etc/nginx
    mkdir -p /etc/nginx/conf.d
    default
    ;;
  3)
    apk update
    apk add build-base pcre-dev zlib-dev openssl-dev git cmake linux-headers perl luajit-dev libtool automake autoconf
    wget https://nginx.org/download/nginx-1.27.5.tar.gz
    tar -xzvf nginx-1.27.5.tar.gz
    cd nginx-1.27.5
    git clone --depth=1 -b OpenSSL_1_1_1u+quic https://github.com/quictls/openssl.git
    git clone https://github.com/simpl/ngx_devel_kit.git
    git clone https://github.com/openresty/lua-nginx-module.git
    ./configure \
      --prefix=/etc/nginx \
      --sbin-path=/usr/sbin/nginx \
      --conf-path=/etc/nginx/nginx.conf \
      --with-http_v3_module \
      --with-http_ssl_module \
      --with-http_v2_module \
      --with-http_gzip_static_module \
      --with-http_realip_module \
      --with-stream \
      --with-http_stub_status_module \
      --with-openssl=./openssl \
      --with-cc-opt="-I./openssl/include -I/usr/include/luajit-2.1" \
      --with-ld-opt="-L./openssl -lluajit-5.1" \
      --add-module=./ngx_devel_kit \
      --add-module=./lua-nginx-module
      make
      make install
      cd ..
      cat > /etc/init.d/nginx<<'EOF' 
#!/sbin/openrc-run

description="nginx web server"

command="/usr/sbin/nginx"
command_args="-c /etc/nginx/nginx.conf"
pidfile="/run/nginx.pid"

depend() {
    need net
    use dns logger
    provide nginx
}

start() {
    ebegin "Starting nginx"
    start-stop-daemon --start --exec $command -- $command_args
    eend $?
}

stop() {
    ebegin "Stopping nginx"
    start-stop-daemon --stop --pidfile $pidfile --retry TERM/30/KILL/5
    eend $?
}

reload() {
    ebegin "Reloading nginx configuration"
    if [ -f "$pidfile" ]; then
        kill -HUP $(cat $pidfile)
        eend $?
    else
        eerror "PID file not found"
        return 1
    fi
}
EOF
      # delete old 資料夾
      rm -rf nginx-1.27.5 nginx-1.27.5.tar.gz
      chmod +x /etc/init.d/nginx
      rc-update add nginx default
      default
      ;;
  esac
}

install_wpcli_if_needed() {
  if ! command -v wp >/dev/null 2>&1; then
    echo "尚未安裝 WP-CLI，開始下載安裝..."
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar || {
      echo "下載失敗，請檢查網路！"
      return 1
    }
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
    echo "安裝完成，版本：$(wp --allow-root --version | head -n1)"
  fi
}
install_phpmyadmin() {
  echo "🚀 開始安裝 phpMyAdmin ..."

  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}您尚未安裝 Docker，請先安裝！${RESET} "
    return 1
  fi

  # 檢查容器是否存在
  if docker ps -a --format '{{.Names}}' | grep -q "^myadmin$"; then
    echo "⚠️ 偵測到已存在名為 myadmin 的容器，將先刪除..."
    docker rm -f myadmin
  fi

  # 取得隨機未被佔用的端口
  while :; do
    read -p "請輸入 phpMyAdmin 映射端口（留空自動隨機）： " port

    if [[ -z "$port" ]]; then
      port=$(( ( RANDOM % (65535 - 1025) ) + 1025 ))
      echo "⚙️ 自動選擇隨機端口：$port"
    fi

    # 更嚴謹檢測
    if ss -tuln | awk '{print $5}' | grep -qE ":$port\$"; then
      echo -e  "${YELLOW}端口 $port 已被佔用，請重新輸入！${RESET}"
    else
      break
    fi
  done
  read -p "是否要自動反向代理？（Y/n）" confirm
  confirm=${confirm,,}
  if [[ $confirm == y || $confirm == "" ]]; then
    read -p "請輸入域名：" domain
    docker run -d \
    --name myadmin \
    -p ${port}:80 \
    -e PMA_HOST=host.docker.internal \
    -e PMA_PORT=3306 \
    -e PMA_ABSOLUTE_URI=https://$domain \
    phpmyadmin/phpmyadmin:latest
    check_cert "$domain" || {
      echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
      if ssl_apply "$domain"; then
        echo "申請成功，重新驗證憑證..."
        check_cert "$domain" || {
          echo "申請成功但仍無法驗證憑證，中止建立站點"
          return 1
        }
      else
        echo "SSL 申請失敗，中止建立站點"
        return 1
      fi
    }
    setup_site "$domain" proxy "127.0.0.1" "http" "$port"
  else
    docker run -d \
    --name myadmin \
    -p ${port}:80 \
    -e PMA_HOST=host.docker.internal \
    -e PMA_PORT=3306 \
    phpmyadmin/phpmyadmin:latest
    echo "===== phpMyAdmin 連結信息 ====="
    echo -e "${YELLOW}請妥善保存${RESET}"
    echo ""
    echo "連結地址：http://localhost:$port"
  fi
}


php_install() {
  echo "🚀 開始安裝 PHP 環境..."
  case $system in
    1)
      local os=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
      apt update
      apt install -y software-properties-common ca-certificates lsb-release gnupg curl

      if [[ $os == "debian" ]]; then
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/ondrej_php.gpg
        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
      elif [[ $os == "ubuntu" ]]; then
        add-apt-repository -y ppa:ondrej/php
      fi

      apt update

      echo "🔍 偵測可用 PHP 版本..."
      local flarum_php_var=$(check_flarum_supported_php)
      local versions=$(apt-cache search ^php[0-9.]+$ | grep -oP '^php\K[0-9.]+' | sort -Vu | awk -F. '$1>=8 {print}')
      if [[ -z "$versions" ]]; then
        echo -e "${RED}❌ 無法取得 PHP 版本列表，請檢查倉庫是否正常。${RESET}"
        return 1
      fi

      echo -e "${YELLOW}可用 PHP 版本如下（僅列出 8.0 以上）：${GREEN}$(echo "$versions" | xargs)${RESET}"
      echo -e "${CYAN}您好，如果您要使用 flarum 的話，這是它現在支援建議的版本，請留意：${GREEN}${flarum_php_var}${RESET}"
      read -p "請輸入要安裝的 PHP 版本（例如 8.3）[預設8.3]: " phpver
      phpver=${phpver:-8.3}
      if ! echo "$versions" | grep -qx "$phpver"; then
        echo -e "${RED}❌ 無效版本號：$phpver{RESET}"
        return 1
      fi

      apt install -y php$phpver php$phpver-fpm php$phpver-mysql php$phpver-curl php$phpver-gd \
        php$phpver-xml php$phpver-mbstring php$phpver-zip php$phpver-intl php$phpver-bcmath php$phpver-imagick unzip redis

      systemctl enable --now php$phpver-fpm
      ;;

    2)
      yum update -y
      yum install -y epel-release
      yum install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
      yum update -y
      yum module reset php -y
      
      local flarum_php_var=$(check_flarum_supported_php)

      local php_versions=$(yum module list php | grep -E '^php\s+(remi-)?8\.[0-9]+' | awk '{print $2}' | sed 's/remi-//' | sort -Vu | xargs)

      if [[ -z "$php_versions" ]]; then
        echo -e "${RED}❌ 無法偵測可用 PHP 模組版本。${RESET}"
        return 1
      fi

      echo -e "${YELLOW}可用 PHP 版本如下（僅列出 8.0 以上）：${GREEN}$(echo "$php_versions" | xargs)${RESET}"
      echo -e "${CYAN}您好，如果您要使用 flarum 的話，這是它現在支援建議的版本，請留意：${GREEN}${flarum_php_var}${RESET}"
      read -p "請輸入要安裝的 PHP 版本（例如 8.3）[預設8.3]: " phpver
      phpver=${phpver:-8.3}

      if [[ ! " $php_versions " =~ " $phpver " ]]; then
        echo -e "${RED}❌ 無效版本號：$phpver${RESET}"
        return 1
      fi

      yum module reset php -y
      yum module enable php:remi-$phpver -y
      yum install -y php php-fpm php-mysqlnd php-curl php-gd php-xml php-mbstring php-zip php-intl php-bcmath php-pecl-imagick unzip redis

      systemctl enable --now php-fpm
      ;;

    3)
      echo "@edgecommunity http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
      apk update
      
      local candidates=$(apk search -x php[0-9]* | grep -oE 'php[0-9]{2}' | sort -u)

      # 擷取可用版本
      local available_versions=""
      
      local flarum_php_var=$(check_flarum_supported_php)
      
      for c in $candidates; do
        if apk info "$c" >/dev/null 2>&1; then
          short=${c#php}
          [[ "$short" -ge 80 ]] && available_versions+=$'\n'"8.${short:1}"
        fi
      done

      # 過濾 80 以下版本
      local filtered_versions=$(echo "$available_versions" | sort -Vu)

      echo -e "${YELLOW}可用 PHP 版本如下（僅列出 8.0 以上）：${GREEN}$(echo "$filtered_versions" | xargs)${RESET}"
      
      echo -e "${CYAN}您好，如果您要使用 flarum 的話，這是它現在支援建議的版本，請留意：${GREEN}${flarum_php_var}${RESET}"

      read -p "請輸入要安裝的 PHP 版本（例如 8.3）[預設8.3]: " phpver
      phpver=${phpver:-8.3}

      if ! echo "$phpver" | grep -qE '^8\.[0-9]+$'; then
        echo -e "${RED}❌ 請輸入有效的 PHP 8.x 版本${RESET}"
        return 1
      fi

      local shortver=$(echo "$phpver" | tr -d '.')

      if ! echo "$available_versions" | grep -q "^8\.${shortver:1}$"; then
        echo -e "${RED}❌ Edge 倉庫中找不到 php$shortver，請確認版本是否正確${RESET}"
        return 1
      fi
      
      if ! apk add --simulate php$shortver>/dev/null 2>&1; then
        echo "您好，您的php版本$phpver無法安裝"
        return 1
      fi

      apk add php$shortver php$shortver-fpm php$shortver-mysqli php$shortver-curl \
        php$shortver-gd php$shortver-xml php$shortver-mbstring php$shortver-zip \
        php$shortver-intl php$shortver-bcmath php$shortver-pecl-imagick php$shortver-phar unzip redis || {
          echo "❌ 安裝失敗，請確認版本是否存在於 Edge 社群源。"
          return 1
        }

      ln -sf /usr/bin/php$shortver /usr/bin/php
      ln -sf /usr/sbin/php$shortver-fpm /usr/sbin/php-fpm
      rc-service php-fpm$shortver start
      rc-update add php-fpm$shortver default
      ;;
  esac
}


php_fix(){
  local php_var=$(check_php_version)
  local ngx_user=$(get_nginx_run_user)

  if [ $system -eq 1 ]; then  # Debian/Ubuntu
    sed -i -r "s|^;?(user\s*=\s*).*|\1$ngx_user|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(group\s*=\s*).*|\1$ngx_user|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(listen.owner\s*=\s*).*|\1$ngx_user|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(listen.group\s*=\s*).*|\1$ngx_user|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(listen.mode\s*=\s*).*|\10660|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(listen\s*=\s*).*|\1/run/php/php-fpm.sock|" /etc/php/$php_var/fpm/pool.d/www.conf
    chown_set
    systemctl restart php$php_var-fpm

  elif [ $system -eq 2 ]; then  # CentOS/RHEL
    sed -i "s|^user *=.*|user = $ngx_user|" /etc/php-fpm.d/www.conf
    sed -i "s|^group *=.*|group = $ngx_user|" /etc/php-fpm.d/www.conf
    sed -i "s|^listen.owner *=.*|listen.owner = $ngx_user|" /etc/php-fpm.d/www.conf
    sed -i "s|^listen.group *=.*|listen.group = $ngx_user|" /etc/php-fpm.d/www.conf
    sed -i "s|^listen =.*|listen = /run/php/php-fpm.sock|" /etc/php-fpm.d/www.conf
    sed -i "s|^listen.mode *=.*|listen.mode = 0660|" /etc/php-fpm.d/www.conf
    chown_set
    systemctl restart php-fpm

  elif [ $system -eq 3 ]; then  # Alpine
    sed -i "s/^user =.*/user = $ngx_user/" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s/^group =.*/group = $ngx_user/" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s|^listen =.*|listen = /run/php/php-fpm.sock|" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s/^;listen.owner =.*/listen.owner = $ngx_user/" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s/^;listen.group =.*/listen.group = $ngx_user/" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s/^;listen.mode =.*/listen.mode = 0660/" /etc/php$php_var/php-fpm.d/www.conf
    chown_set
    rc-service php-fpm$php_var restart
  fi
}


php_switch_version() {
  echo "🔄 開始 PHP 升級/降級程序..."
  case $system in
  1)
    oldver=$(check_php_version)
    local versions=$(apt-cache search ^php[0-9.]+$ | grep -oP '^php\K[0-9.]+' | sort -Vu | awk -F. '$1>=8 {print}')
    ;;
  2)
    oldver=$(check_php_version)
    local versions=$(yum module list php | grep -E '^php\s+(remi-)?8\.[0-9]+' | awk '{print $2}' | sed 's/remi-//' | sort -Vu | xargs)
    ;;
  3)
    local oldver=$(php -v | head -n1 | grep -oE '[0-9]+\.[0-9]+') # 8.3
    local candidates=$(apk search -x php[0-9]* | grep -oE 'php[0-9]{2}' | sort -u)

      # 擷取可用版本
      local available_versions=""
      
      for c in $candidates; do
        if apk info "$c" >/dev/null 2>&1; then
          short=${c#php}
          [[ "$short" -ge 80 ]] && available_versions+=$'\n'"8.${short:1}"
        fi
      done

      # 過濾 80 以下版本
      local versions=$(echo "$available_versions" | sort -Vu)
    ;;
  esac
  

  echo "目前安裝的 PHP 版本為：$oldver"
  echo "可升級/降級版本：$versions"
  read -p "請輸入要升級/降級的 PHP 版本（例如 8.3）[預設與目前相同]: " newver
  newver=${newver:-$oldver}
  shortold=$(echo "$oldver" | tr -d '.')
  shortnew=$(echo "$newver" | tr -d '.')

  echo "準備擷取舊版已安裝擴充模組..."
  case $system in
    1)
      mapfile -t exts < <(dpkg -l | grep "^ii  php$oldver-" | awk '{print $2}' | grep -oP "(?<=php$oldver-).*" | grep -vE '^(fpm|cli|common)$')
      ;;
    2)
      mapfile -t exts < <(
        rpm -qa | grep "^php-" |
        grep -vE '^php-(cli|fpm|common|[0-9]+\.[0-9]+)' |
        sed -E 's/^php-pecl-//; s/^php-//' |
        sed -E 's/(-im[0-9]+)?-[0-9].*$//' |
        sort -u
      )
      ;;
    3)
      mapfile -t exts < <(apk info | grep "^php$shortold-" | sed "s/php$shortold-//" | grep -vE '^(fpm|cli|common)$')
      ;;
    *)
      echo "不支援的系統"
      return 1
      ;;
  esac

  echo "🔌 已偵測的擴充模組：${exts[*]:-無}"
  
  case $system in
  3)
    echo "偵測是否能順利安裝..."
    if ! apk add --simulate php$shortnew>/dev/null 2>&1; then
      echo "您好，您的php版本$phpver無法安裝"
      return 1
    fi
    ;;
  esac

  echo "⛔ 停止 PHP 與 Web 服務..."
  case $system in
    1)
      systemctl stop php$oldver-fpm 2>/dev/null
      systemctl disable php$oldver-fpm 2>/dev/null
      systemctl stop nginx 2>/dev/null
      systemctl stop openresty 2>/dev/null
      ;;
    2)
      systemctl stop php-fpm 2>/dev/null
      systemctl disable php-fpm 2>/dev/null
      systemctl stop nginx 2>/dev/null
      systemctl stop openresty 2>/dev/null
      ;;
    3)
      rc-service php-fpm$shortold stop 2>/dev/null
      rc-update del php-fpm$shortold default
      rc-service nginx stop 2>/dev/null
      ;;
  esac

  echo "🧹 移除舊版 PHP..."
  case $system in
    1)
      apt purge -y php$oldver* ;;
    2)
      yum module reset php -y
      mapfile -t php_packages < <(rpm -qa | grep "^php-" | awk '{print $1}')
      if [[ ${#php_packages[@]} -eq 0 ]]; then
        echo "⚠️ 未發現任何 PHP 套件可移除。"
      else
        echo "🔻 即將移除下列 PHP 套件："
        printf ' - %s\n' "${php_packages[@]}"
        yum remove -y --noautoremove "${php_packages[@]}"
      fi
      ;;
    3)
      apk del php$shortold* ;;
  esac

  echo "⬇️ 安裝新版 PHP：$newver"
  case $system in
    1)
      apt install php$newver php$newver-fpm -y
      ;;
    2)
      yum module enable php:remi-$newver -y 
      yum install php php-fpm -y
      ;;
    3)
      apk add php$shortnew php$shortnew-fpm
      ;;
  esac

  echo "📦 重新安裝擴充模組..."
  for ext in "${exts[@]}"; do
    echo " - 重新安裝模組：$ext"
    case $system in
      1) apt install -y php$newver-$ext ;;
      2) yum install -y php-$ext ;;
      3) apk add php$shortnew-$ext ;;
    esac
  done

  echo "🚀 重新啟動服務..."
  case $system in
    1)
      systemctl enable php$newver-fpm
      systemctl restart php$newver-fpm
      systemctl start openresty
      ;;
    2)
      systemctl enable php-fpm
      systemctl restart php-fpm
      systemctl start openresty
      ;;
    3)
      rc-update add php-fpm$shortnew default
      rc-service php-fpm$shortnew restart
      rc-service nginx start
      ;;
  esac
  php_fix

  echo "✅ PHP 升級/降級完成（從 $oldver → $newver）"
}


php_tune_upload_limit() {
  local php_var=$(check_php_version)
  if ! command -v php >/dev/null 2>&1; then
    echo "未偵測到 PHP，請先安裝 PHP 後再使用此功能。"
    return 1
  fi

  if [ $system -eq 1 ]; then
    php_ini=/etc/php/$php_var/fpm/php.ini
  else
    php_ini=$(php -i | grep "Loaded Configuration File" | awk '{print $5}')
  fi
  if [ ! -f "$php_ini" ]; then
    echo "無法找到 php.ini，無法調整上傳限制。"
    return 1
  fi

  echo "目前使用的 php.ini：$php_ini"
  read -p "請輸入最大上傳大小（例如 64M、100M、1G，預設 64M）：" max_upload
  max_upload="${max_upload:-64M}"

  # 將 max_upload 轉成 MB 數值（單位大小推算）
  unit=$(echo "$max_upload" | grep -oEi '[MG]' | tr '[:lower:]' '[:upper:]')
  value=$(echo "$max_upload" | grep -oE '^[0-9]+')

  if [ "$unit" == "G" ]; then
    post_size="$((value * 2))G"
  elif [ "$unit" == "M" ]; then
    post_size="$((value * 2))M"
  else
    echo "格式錯誤，請輸入例如 64M 或 1G"
    return 1
  fi

  # 固定設定 memory_limit 為 1536M（1.5GB）
  memory_limit="1536M"

  # 修改 php.ini 內容
  sed -i "s/^\s*upload_max_filesize\s*=.*/upload_max_filesize = $max_upload/" "$php_ini"
  sed -i "s/^\s*post_max_size\s*=.*/post_max_size = $post_size/" "$php_ini"
  sed -i "s/^\s*memory_limit\s*=.*/memory_limit = $memory_limit/" "$php_ini"

  echo "✅ 已設定："
  echo "  - upload_max_filesize = $max_upload"
  echo "  - post_max_size = $post_size"
  echo "  - memory_limit = $memory_limit"

  # 重啟 php-fpm
  if [ $system -eq 1 ]; then
    systemctl restart php$php_var-fpm
  elif [ $system -eq 2 ]; then
    systemctl restart php-fpm
  elif [ $system -eq 3 ]; then
    rc-service php-fpm$php_var restart
  fi

  echo "✅ PHP FPM 已重新啟動"
}

php_install_extensions() {
  local php_var=$(check_php_version)

  read -p "請輸入要安裝的 PHP 擴展名稱（如：gd、mbstring、curl、intl、zip、imagick 等）: " ext_name
  if [ -z "$ext_name" ]; then
    echo "未輸入擴展名稱，中止操作。"
    return 1
  fi

  echo -n "🔍 檢查 PHP 擴展：$ext_name ... "
  if php -m | grep -Fxiq -- "$ext_name"; then
    echo "✅ 已安裝"
    return 0
  fi

  if ! check_php_ext_available "$ext_name" "$php_var"; then
    echo "❌ 擴展 $ext_name 不存在於倉庫，無法安裝"
    return 1
  fi

  echo "📦 倉庫中找到 $ext_name，開始安裝..."

  case $system in
    1)
      apt update
      apt install -y php$php_var-$ext_name
      systemctl restart php$php_var-fpm
      ;;
    2)
      yum install -y php-$ext_name || yum install -y php-pecl-$ext_name
      systemctl restart php-fpm
      ;;
    3)
      apk update
      apk add php$php_var-$ext_name
      rc-service php-fpm$php_var restart
      ;;
    *)
      echo "不支援的系統類型。"
      return 1
      ;;
  esac

  if php -m | grep -Fxiq -- "$ext_name"; then
    echo "✅ PHP 擴展 $ext_name 安裝成功。"
  else
    echo "❌ PHP 擴展 $ext_name 安裝失敗，請檢查錯誤訊息。"
    return 1
  fi
}



reverse_proxy(){
  read -p "請輸入網址（格式：(example.com))：" domain
  read -p "請輸入反向代理網址（如果是容器,則不用填,預設127.0.0.1）：" target_url
  read -p "請輸入反向代理網址的端口號：" target_port
  echo "正在檢查輸入的網址..."
  if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
    echo "端口號必須在1到65535之間。"
    return 1
  fi
  read -p "請輸入反向代理的http(s)(如果是容器的話預設是http):" target_protocol
  target_url=${target_url:-127.0.0.1}
  target_protocol=${target_protocol:-http}
  check_cert "$domain" || {
    echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
    if ssl_apply "$domain"; then
      echo "申請成功，重新驗證憑證..."
        check_cert "$domain" || {
          echo "申請成功但仍無法驗證憑證，中止建立站點"
          return 1
        }
    else
      echo "SSL 申請失敗，中止建立站點"
      return 1
    fi
  }
  setup_site "$domain" proxy "$target_url" "$target_protocol" "$target_port"
  echo "已建立 $domain 反向代理站點。"
}

restart_nginx_openresty() {
  if [ "$openresty" -eq "1" ]; then
    service openresty restart
  elif [ "$nginx" -eq "1" ]; then
    service nginx restart
  fi
}

# 只列出有自動備份排程的網站，讓用戶選擇移除
remove_site_backup_cron() {
  echo "============【 移除網站自動備份排程 】============"
  local crontab_lines
  crontab_lines=$(crontab -l 2>/dev/null | grep '/var/www/' || true)
  if [[ -z "$crontab_lines" ]]; then
    echo "❌ 目前沒有任何網站有自動備份排程。"
    return 1
  fi
  # 從 crontab 取唯一網站
  local sites=()
  while read -r line; do
    site=$(echo "$line" | grep -o '/var/www/[^ ]*' | awk -F/ '{print $4}')
    [[ -n "$site" ]] && sites+=("$site")
  done <<< "$(echo "$crontab_lines" | sort | uniq)"
  # 去重
  local uniq_sites=()
  local seen=""
  for s in "${sites[@]}"; do
    [[ "$seen" =~ " $s " ]] || uniq_sites+=("$s")
    seen+=" $s "
  done
  if [[ ${#uniq_sites[@]} -eq 0 ]]; then
    echo "❌ 沒有偵測到任何網站有自動備份排程。"
    return 1
  fi
  echo "可移除排程的網站："
  local i=1
  for site in "${uniq_sites[@]}"; do
    echo "  [$i] $site"
    ((i++))
  done
  read -p "請輸入要移除排程的網站編號：" idx
  if [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#uniq_sites[@]} )); then
    echo "❌ 輸入無效，取消操作。"
    return 1
  fi
  local domain="${uniq_sites[$((idx-1))]}"
  crontab -l 2>/dev/null | grep -v "/var/www/$domain" | crontab -
  echo "✅ 已移除 $domain 的自動備份排程（不影響現有備份檔案）。"
}



reset_wp_site() {
  local domain="$1"
  local path="/var/www/$domain"
  local wp_cli="wp --allow-root"

  # 檢查該路徑是否是 WordPress
  if [ ! -f "$path/wp-config.php" ]; then
    echo "❌ $domain 不是 WordPress 網站！"
    return 1
  fi

  echo "🚨 正在對 $domain 執行 WordPress 緊急重置..."

  # 停用全部外掛
  $wp_cli plugin deactivate --all --path="$path" || \
    echo "⚠️ 停用外掛失敗。"

  # 嘗試找預設主題
  default_theme=$($wp_cli theme list --path="$path" --status=inactive --field=name | grep -E '^twenty' | head -n 1)

  if [ -z "$default_theme" ]; then
    echo "⚠️ 未發現預設佈景主題，嘗試安裝 Twenty Twenty-Four..."
    $wp_cli theme install twentytwentyfour --path="$path"
    default_theme="twentytwentyfour"
  fi

  $wp_cli theme activate "$default_theme" --path="$path" || \
    echo "⚠️ 切換佈景主題失敗。"

  echo "✅ $domain 已完成緊急重置。可嘗試重新登入後台。"
}


restore_site_files() {
  local mode="$1"
  local domain="$2"

  local dest_dir="/var/www/$domain"
  read -p "請輸入備份檔路徑 (.tar.gz / .zip)：" archive

  if [[ ! -f "$archive" ]]; then
    echo "⚠️ 檔案不存在：$archive"
    return 1
  fi

  echo "📂 準備還原至：$dest_dir"

  if [[ -d "$dest_dir" ]]; then
    read -p "⚠️ 目錄已存在，是否清空目錄後還原？(y/N)：" yn
    case "$yn" in
      [Yy]* ) rm -rf "$dest_dir"/* ;;
      * ) echo "已取消還原。"; return 0 ;;
    esac
  fi

  mkdir -p "$dest_dir"

  echo "🔄 正在解壓 $archive ..."
  if [[ "$archive" == *.tar.gz ]]; then
    tar -xzf "$archive" -C "$dest_dir"
  elif [[ "$archive" == *.zip ]]; then
    unzip -q "$archive" -d "$dest_dir"
  else
    echo "❌ 不支援的壓縮格式"
    return 1
  fi

  echo "✅ [$mode] 檔案還原完成！"

  # 根據 system 呼叫不同的 DB restore
  case "$mode" in
    wp)
      echo "🔁 WordPress 檔案已還原，繼續執行 WordPress 資料庫還原..."
      restore_site_db "$mode" "$domain"
      ;;
    flarum)
      echo "🔁 Flarum 檔案已還原，繼續執行 Flarum 資料庫還原..."
      restore_site_db "$mode" "$domain"
      ;;
    *)
      echo "⚠️ 尚未支援系統：$mode"
      ;;
  esac
}


restore_site_db() {
  local type="$1"
  local domain="$2"
  local site_path="/var/www/$domain"
  local backup_file=""
  local db_name db_user db_pass

  if [[ "$type" == "wp" ]]; then
    local config="$site_path/wp-config.php"
    if [[ ! -f "$config" ]]; then
      echo "❌ 找不到 wp-config.php"
      return 1
    fi

    # 改用更穩定的 awk 擷取方式
    db_name=$(awk -F"'" '/DB_NAME/{print $4}' "$config")  
    db_user=$(awk -F"'" '/DB_USER/{print $4}' "$config")  
    db_pass=$(awk -F"'" '/DB_PASSWORD/{print $4}' "$config")  
    

    # 檢查網站根目錄是否有 .sql 檔案
    local sql_files=("$site_path"/*.sql)
    if [[ ${#sql_files[@]} -gt 0 && -f "${sql_files[0]}" ]]; then
      backup_file="${sql_files[0]}"
      echo "🔍 發現資料庫備份檔: $backup_file"
      read -p "是否要自動還原此檔案？[Y/n] " confirm
      if [[ "$confirm" != [nN] ]]; then
        echo "🔄 開始自動還原..."
      else
        backup_file=""
      fi
    fi

  elif [[ "$type" == "flarum" ]]; then
    local config="$site_path/config.php"
    if [[ ! -f "$config" ]]; then
      echo "❌ 找不到 config.php"
      return 1
    fi

    db_name=$(php -r "
      \$c = include '$config';
      echo \$c['database']['database'] ?? '';
    ")
    db_user=$(php -r "
      \$c = include '$config';
      echo \$c['database']['username'] ?? '';
    ")
    db_pass=$(php -r "
      \$c = include '$config';
      echo \$c['database']['password'] ?? '';
    ")
  else
    echo "❌ 不支援的類型：$type"
    return 1
  fi

  if [[ -z "$db_name" || -z "$db_user" ]]; then
    echo "❌ 無法讀取 DB 設定"
    return 1
  fi

  if [[ -z "$backup_file" ]]; then
    read -p "請輸入備份檔路徑 (.sql)：" backup_file
    if [[ ! -f "$backup_file" ]]; then
      echo "⚠️ 檔案不存在：$backup_file"
      return 1
    fi
  fi

  # 檢查 root 權限
  local mysql_cmd="mysql -uroot"
  if ! $mysql_cmd -e ";" &>/dev/null; then
    if [[ -f /etc/mysql-pass.conf ]]; then
      mysql_root_pass=$(cat /etc/mysql-pass.conf)
      mysql_cmd="mysql -uroot -p$mysql_root_pass"
    else
      read -s -p "請輸入 MySQL root 密碼：" mysql_root_pass
      echo
      mysql_cmd="mysql -uroot -p$mysql_root_pass"
    fi
    if ! $mysql_cmd -e ";" &>/dev/null; then
      echo "❌ 無法登入 MySQL"
      return 1
    fi
  fi

  echo "🔍 檢查資料庫是否存在：$db_name"
  if ! $mysql_cmd -e "USE \`$db_name\`;" 2>/dev/null; then
    echo "⚠️ 資料庫 $db_name 不存在，將自動建立..."
    $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  else
    echo "⚠️ 資料庫已存在，清空所有資料表..."
    local tables=$($mysql_cmd -N -e "SHOW TABLES FROM \`$db_name\`;")
    for table in $tables; do
      echo "🧹 刪除表：$table"
      $mysql_cmd -e "DROP TABLE \`$db_name\`.\`$table\`;"
    done
    echo "✅ 已清空資料表"
  fi

  echo "🚀 匯入資料中..."
  $mysql_cmd "$db_name" < "$backup_file"

  # 匯入後檢查
  local tables_after=$($mysql_cmd -N -e "SHOW TABLES FROM \`$db_name\`;")
  if [[ -z "$tables_after" ]]; then
    echo "⚠️ 匯入後資料表為空，請檢查 SQL 檔或 DB 權限！"
    return 1
  fi

  # 建立 user 並授權
  local user_exists=$($mysql_cmd -N -e "SELECT User FROM mysql.user WHERE User='$db_user';")
  if [[ -z "$user_exists" ]]; then
    echo "⚠️ 使用者 $db_user 不存在，將自動建立..."
    $mysql_cmd -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
  fi

  local grants=$($mysql_cmd -N -e "SHOW GRANTS FOR '$db_user'@'localhost';" | grep "\`$db_name\`")
  if [[ -z "$grants" ]]; then
    echo "⚠️ 使用者 $db_user 尚未擁有 $db_name 權限，將授權..."
    $mysql_cmd -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost' IDENTIFIED BY '$db_pass'; FLUSH PRIVILEGES;"
  fi

  # 如果是自動偵測的備份檔，還原後刪除
  if [[ "$backup_file" == "$site_path/"*.sql ]]; then
    echo "🧹 刪除已還原的備份檔: $backup_file"
    rm -f "$backup_file"
  fi

  echo "✅ $type 資料庫 [$db_name] 還原完成"
}



setup_site_http2(){
  local domain=$1
  local http3=$(check_http3_support)

  local conf_file=$(detect_conf_path)/$domain.conf

  if [[ "$http3" != "true" ]]; then
    if command -v nginx >/dev/null 2>&1; then
      local ngx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    elif command -v openresty >/dev/null 2>&1; then
      local ngx_ver=$(openresty -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    fi
    if [ "$(printf '%s\n' "$ngx_ver" "1.25.1" | sort -V | head -n1)" != "1.25.1" ]; then
      sed -i -e '/http2 on/d' "$conf_file"
      # 把 listen 443 ssl; 變成 listen 443 ssl http2;
      sed -i -E 's/(listen\s+443\s+ssl)(;)/\1 http2\2/' "$conf_file"
      sed -i -E 's/(listen\s+\[::\]:443\s+ssl)(;)/\1 http2\2/' "$conf_file"
    fi
    # 刪除所有 HTTP/3 + QUIC 相關設定
    sed -i \
      -e '/listen.*quic/d' \
      -e '/http3 on/d' \
      -e '/http2 on/d' \
      -e '/Alt-Svc/d' \
      -e '/QUIC-Status/d' \
      "$conf_file"


    echo "✅ 已刪除 $conf_file 中所有 HTTP/3 / QUIC 相關配置，並啟用 HTTP/2"
  fi
}


setup_site() {
  local domain=$1
  local type=$2
  local domain_cert=$(check_cert "$domain" | tail -n 1 | tr -d '\r\n')
  local escaped_cert=$(printf '%s' "$domain_cert" | sed 's/[&/\]/\\&/g') # 取得主域名或泛域名作為憑證目錄
  local conf_file=$(detect_conf_path)/$domain.conf
  clean_ssl_session_cache

  case $system in
    1|2|3)
      case $type in
        html|php|www|flarum|phpmyadmin)
          local conf_url="https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/domain_${type}.conf"
          wget -O "$conf_file" "$conf_url"
          sed -i -e "s|domain|$domain|g" \
            -e "s|main|$escaped_cert|g" \
            "$conf_file"
          setup_site_http2 "$domain"
          if nginx -t; then
            restart_nginx_openresty
          else
            echo "nginx 測試失敗，請檢查配置"
            return 1
          fi
          ;;
        proxy)
          local target_url=$3
          local target_protocol=$4
          local target_port=$5
          wget -O "$conf_file" https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/domain_proxy.conf
          sed -i "s|proxy_pass host:port;|proxy_pass $target_protocol://$target_url:$target_port;|g" "$conf_file"
          sed -i -e "s|domain|$domain|g" \
            -e "s|main|$escaped_cert|g" \
            "$conf_file"
          setup_site_http2 "$domain"
          if nginx -t; then
            restart_nginx_openresty
          else
            echo "nginx測試失敗"
            return 1
          fi
          ;;
        *)
          echo "不支援的類型: $type"; return 1;;
      esac
      ;;
  esac
}

show_registered_cas() {
  echo "===== 已註冊憑證機構郵箱如下 ====="
  for ca in letsencrypt zerossl google; do
    email=$(awk -v section="[$ca]" '
      $0 == section { found=1; next }
      /^.*/ { found=0 }
      found && /^email=/ { print substr($0,7); exit }
    ' /ssl_ca/.ssl_ca_emails 2>/dev/null)
    
    if [ -n "$email" ]; then
      echo "$ca：$email"
    else
      echo "$ca：未註冊"
    fi
  done
  echo "==================================="
}


select_ca() {
  mkdir -p /ssl_ca
  show_registered_cas
  echo "請選擇你要註冊的憑證簽發機構："
  echo "1. Let's Encrypt (預設)"
  echo "2. ZeroSSL"
  echo "3. Google Trust Services"
  read -rp "選擇 [1-3]: " ca_choice

  case "$ca_choice" in
    2)
      echo "請先註冊zeroSSL帳號"
      echo "接著到這個網址生成EAB Credentials for ACME Clients：https://app.zerossl.com/developer"
      read -p "您的EAB KID：" eab_kid
      read -p "您的EAB HMAC Key" eab_key
      read -p "您的郵箱：" zero_email
      certbot register \
        --email $zero_email \
        --no-eff-email \
        --server "https://acme.zerossl.com/v2/DV90" \
        --eab-kid "$eab_kid" \
        --eab-hmac-key "$eab_key"
      set_ca_email "zerossl" "$zero_email"
      ;;
    3)
      echo "首先你需要有一個google帳號"
      echo "打開此網址並啟用api，請記得選一個專案：https://console.cloud.google.com/apis/library/publicca.googleapis.com"
      echo "打開Cloud Shell 並輸入：gcloud beta publicca external-account-keys create"
      read -p "請輸入keyId：" goog_id
      read -p "請輸入Key：" goog_eab_key
      read -p "請輸入您註冊的郵箱" goog_email
      certbot register \
        --email "$goog_email" \
        --no-eff-email \
        --server "https://dv.acme-v02.api.pki.goog/directory" \
        --eab-kid "$goog_id" \
        --eab-hmac-key "$goog_eab_key"
      set_ca_email "google" "$goog_email"
      ;;
    *)
      read -p "請輸入您的郵箱：" le_email
      certbot register \
        --email "$le_email" \
        --no-eff-email \
        --server "https://acme-v02.api.letsencrypt.org/directory"
      set_ca_email "letsencrypt" "$le_email"
      ;;
  esac
}
set_ca_email() {
  mkdir -p /ssl_ca
  if [ ! -f /ssl_ca/.ssl_ca_emails ]; then
  cat > /ssl_ca/.ssl_ca_emails << EOF
[letsencrypt]
email=

[zerossl]
email=

[google]
email=
EOF
  fi
  local ca_name=$1
  local email=$2

  # 刪除現有的該 CA 的段落，包括郵箱行
  sed -i "/^\[$ca_name\]$/,/^$/d" /ssl_ca/.ssl_ca_emails 2>/dev/null
  
  # 在文件最上方插入新的 CA 段落
  if [ "$ca_name" == "letsencrypt" ]; then
    # 如果是letsencrypt，把它插入到文件最前面
    sed -i "1i[$ca_name]\nemail=$email\n" /ssl_ca/.ssl_ca_emails
  else
    # 其他CA，照常追加到文件末尾
    echo -e "[$ca_name]\nemail=$email\n" >> /ssl_ca/.ssl_ca_emails
  fi
}
show_cert_status() {
  check_web_environment
  if [[ $use_my_app != true ]]; then
    echo -e "===== Nginx 站點憑證狀態 ====="
    echo -e "${RED}您好,您現在使用其他web server 無法使用站點憑證狀態之功能${RESET}"
  else
    echo -e "===== Nginx 站點憑證狀態 ====="
    printf "%-30s | %-20s | %-20s | %-10s | %s\n" "域名" "到期日" "憑證資料夾" "狀態" "備註"
    echo "------------------------------------------------------------------------------------------------------"

    local CERT_PATH="/etc/letsencrypt/live"
    local nginx_conf_paths=$(detect_conf_path)

    # 讀取所有 server_name 域名
    local nginx_domains
    nginx_domains=$(grep -rhoE 'server_name\s+[^;]+' "$nginx_conf_paths" 2>/dev/null | \
      sed -E 's/server_name\s+//' | tr ' ' '\n' | grep -E '^[a-zA-Z0-9.-]+$' | sort -u)

    for nginx_domain in $nginx_domains; do
      local matched_cert="-"
      local end_date="無憑證"
      local status=$'\e[31m未使用/錯誤\e[0m'
      local note=""

      local exact_match_cert=""
      local exact_match_date=""
      local wildcard_match_cert=""
      local wildcard_match_date=""

      for cert_dir in "$CERT_PATH"/*; do
        [[ -d "$cert_dir" ]] || continue
        local cert_file="$cert_dir/cert.pem"
        [[ -f "$cert_file" ]] || continue

        # 取得憑證 SAN 清單（去掉 DNS: 且換行）
        local san_list
        san_list=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | \
          awk '/X509v3 Subject Alternative Name/ {getline; gsub("DNS:", ""); gsub(", ", "\n"); print}')

        for san in $san_list; do
          if [[ "$san" == "$nginx_domain" ]]; then
            exact_match_cert=$(basename "$cert_dir")
            exact_match_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
            break 2
          elif [[ "$san" == \*.* ]]; then
            local base_domain="${san#*.}"
            if [[ "$nginx_domain" == *".${base_domain}" ]]; then
              if [[ -z "$wildcard_match_cert" ]]; then
                wildcard_match_cert=$(basename "$cert_dir")
                wildcard_match_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
              fi
            fi
          fi
        done
      done

      if [[ -n "$exact_match_cert" ]]; then
        matched_cert="$exact_match_cert"
        end_date="$exact_match_date"
        status="是"
      elif [[ -n "$wildcard_match_cert" ]]; then
        matched_cert="$wildcard_match_cert"
        end_date="$wildcard_match_date"
        status="泛域名命中"
      fi

      # 判斷是否為 Cloudflare Origin 憑證
      if [[ -d "$CERT_PATH/$matched_cert" ]] && [[ -f "$CERT_PATH/$matched_cert/cf_cert_id.txt" ]]; then
        note="CF Origin"
      fi

      printf "%-30s | %-20s | %-20s | %-10s | %s\n" "$nginx_domain" "$end_date" "$matched_cert" "$status" "$note"
    done
  fi
}

show_httpguard_status(){

  get_module_state() {
  # 自動偵測 config.lua 路徑
  if [ -f "/usr/local/openresty/nginx/conf/HttpGuard/config.lua" ]; then
    config_file="/usr/local/openresty/nginx/conf/HttpGuard/config.lua"
  elif [ -f "/etc/nginx/HttpGuard/config.lua" ]; then
    config_file="/etc/nginx/HttpGuard/config.lua"
  else
    echo "錯誤：HttpGuard/config.lua 未找到。請確認安裝目錄或文件路徑。"
    return 1
  fi
    local module_name=$1
    grep -E "^\s*${module_name}\s*=" "$config_file" | grep -oE 'state\s*=\s*"[^"]+"' | head -n1 | grep -oE '"[^"]+"' | tr -d '"'
  }

  echo "--- HttpGuard 主動防禦與自動開啟狀態 ---"

  redirect_state=$(get_module_state "redirectModules")
  jsjump_state=$(get_module_state "JsJumpModules")
  cookie_state=$(get_module_state "cookieModules")
  auto_enable_state=$(get_module_state "autoEnable")
  
  echo -e "${CYAN}主動防禦 (302 Redirect Modules) 狀態: ${redirect_state:-未找到} ${RESET}"
  echo -e "${CYAN}主動防禦 (JS Jump Modules) 狀態: ${jsjump_state:-未找到} ${RESET}"
  echo -e "${CYAN}主動防禦 (Cookie Modules) 狀態: ${cookie_state:-未找到} ${RESET}"
  echo -e "${CYAN}自動開啟主動防禦 狀態: ${auto_enable_state:-未找到} ${RESET}"
  echo "-------------------------------------"
}


show_php() {
  local wp_root="/var/www"
  echo "===== 已安裝 PHP 網站列表 ====="
  printf "%-20s | %-10s\n" "網址" "備註"
  echo "-------------------------------------------"

  for site_dir in "$wp_root"/*; do
    if [ -d "$site_dir" ]; then
      site_name=$(basename "$site_dir")

      # 判斷是否為有效網址型資料夾（必須包含 .）
      if [[ "$site_name" != *.* ]]; then
        continue
      fi

      # 必須有 index.php 才處理
      if [[ ! -f "$site_dir/index.php" ]]; then
        continue
      fi

      remark="PHP網站"

      if [[ -f "$site_dir/wp-config.php" ]]; then
        remark="WordPress"
      elif [[ -f "$site_dir/public/assets/forum.js" ]] || grep -qi "flarum" "$site_dir/index.php" 2>/dev/null; then
        remark="Flarum"
      elif [[ -f "$site_dir/usr/index.php" ]] || grep -qi "Typecho" "$site_dir/index.php" 2>/dev/null; then
        remark="Typecho"
      fi

      printf "%-20s | %-10s\n" "$site_name" "$remark"
    fi
  done
}

ssl_apply() {
  check_certbot
  update_certbot
  mkdir -p /ssl_ca
  
  local domains="$1"
  if [ -z "$domains" ]; then
    read -p "請輸入您的域名（只能用空白鍵分隔）：" domains
  fi

  # 讀取已註冊的 CA email
  declare -A ca_emails
  local current_ca=""
  local current_ca_config="/ssl_ca/.ssl_ca_emails"
  if [ -f "$current_ca_config" ]; then
    while IFS="=" read -r key val; do
      # 檢查是否為新段落
      if [[ $key =~ ^\[(.*)\]$ ]]; then
        current_ca="${BASH_REMATCH[1]}"
        continue
      fi
      # 只有當 current_ca 有值且 email 不為空時才賦值
      if [[ -n "$current_ca" && $key == "email" && -n "$val" ]]; then
        ca_emails["$current_ca"]="$val"
      fi
    done < "$current_ca_config"
  fi

  echo "偵測到以下已註冊的 CA："
  ca_options=()
  index=1
  for ca in letsencrypt zerossl google; do
    if [ -n "${ca_emails[$ca]}" ]; then
      echo "$index) $ca（${ca_emails[$ca]}）"
      ca_options+=("$ca")
      ((index++))
    fi
  done

  if [ ${#ca_options[@]} -eq 0 ]; then
    echo "尚未註冊任何憑證簽發機構，直接輸入電子郵件。"
    selected_ca="letsencrypt"
    read -p "請輸入電子郵件：" selected_email
    certbot register \
      --email "$selected_email" \
      --no-eff-email \
      --server "https://acme-v02.api.letsencrypt.org/directory"
    set_ca_email "letsencrypt" "$selected_email"
    
  elif [ ${#ca_options[@]} -eq 1 ]; then
    echo "僅有一個已註冊 CA，將自動選擇：${ca_options[0]}（${ca_emails[${ca_options[0]}]}）"
    selected_ca="${ca_options[0]}"
    selected_email="${ca_emails[$selected_ca]}"
  else
    read -p "請選擇您要使用的 CA [1-${#ca_options[@]}]（預設 1）：" choice
    choice="${choice:-1}"
    selected_ca="${ca_options[$((choice-1))]}"
    selected_email="${ca_emails[$selected_ca]}"
  fi

  case "$selected_ca" in
    zerossl)
      server_url="https://acme.zerossl.com/v2/DV90"
      ;;
    google)
      server_url="https://dv.acme-v02.api.pki.goog/directory"
      ;;
    *)
      server_url="https://acme-v02.api.letsencrypt.org/directory"
      ;;
  esac

  echo "選擇驗證方式："
  echo "1) DNS (Cloudflare)"
  echo "2) DNS (其他供應商)"
  echo "3) HTTP"
  read -p "選擇 [1-3]（預設 3）:" auth_method
  auth_method="${auth_method:-3}"

  IFS=$' ,\n' read -ra domain_array <<< "$domains"
  domain_args=()
  for d in "${domain_array[@]}"; do
    domain_args+=("-d" "$d")
  done

  if [ "$auth_method" = 1 ]; then
    if [ -f "/ssl_ca/cloudflare/cloudflare.ini" ]; then
      local cred_file="/ssl_ca/cloudflare/cloudflare.ini"
    else
      mkdir -p /ssl_ca/cloudflare
      read -s -p "請輸入您的 Cloudflare API Token(非Global API Key)：" cf_token
      cred_file="/ssl_ca/cloudflare/cloudflare.ini"
      echo "dns_cloudflare_api_token = $cf_token" > "$cred_file"
      chmod 600 "$cred_file"
    fi
    certbot certonly \
      --dns-cloudflare \
      --dns-cloudflare-credentials "$cred_file" \
      --dns-cloudflare-propagation-seconds 60 \
      --email "$selected_email" \
      --key-type rsa \
      --agree-tos \
      --server "$server_url" \
      --non-interactive \
      "${domain_args[@]}"
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -
    echo "已加入自動續訂任務（每天凌晨3點）"

      # 啟動 crond
      case $system in
        1)
          systemctl enable cron
          systemctl start cron
          ;;
        2)
          systemctl enable crond
          systemctl start crond
          ;;
        3)
          rc-update add crond default
          rc-service crond start
          ;;
      esac
    fi
  elif [ "$auth_method" = 2 ]; then
    echo "您好,此DNS不支持自動續訂,是否繼續? (y/n)"
    read -r continue_choice
    if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
      echo "已取消操作。"
      return 1
    fi
    certbot certonly \
      --manual \
      --preferred-challenges "dns-01" \
      --email "$selected_email" \
      --key-type rsa \
      --agree-tos \
      --server "$server_url" \
      "${domain_args[@]}"

  else
    if [[ "$domains" =~ \*\. ]]; then
      echo "您好,HTTP驗證不能使用泛域名"
    return 1
    fi
    if [ "$selected_ca" = "google" ] && [ "$auth_method" = "3" ]; then
      echo "錯誤：Google CA 不支援 HTTP 驗證，請選擇 DNS 驗證方式（選項 1 或 2）"
      return 1
    fi
    clean_ssl_session_cache
    local detect_conf_path=$(detect_conf_path)
  
  
    # 建立 open_port.sh
    cat > /ssl_ca/open_port.sh <<'EOF'
#!/bin/bash
firewall=0
if command -v ufw >/dev/null 2>&1; then
  firewall=1
elif command -v iptables >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
  firewall=2
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall=3
fi

action="$1"
port="${2:-80}"

if [ "$firewall" -eq 1 ]; then
  if [ "$action" = "add" ]; then
    ufw status | grep -qw "$port" || ufw allow "$port"
  else
    ufw delete allow "$port" >/dev/null 2>&1 || true
  fi
elif [ "$firewall" -eq 2 ]; then
  if [ "$action" = "add" ]; then
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
  else
    iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
  fi
elif [ "$firewall" -eq 3 ]; then
  if [ "$action" = "add" ]; then
    firewall-cmd --quiet --add-port="$port"/tcp || true
  else
    firewall-cmd --quiet --remove-port="$port"/tcp || true
  fi
fi
EOF
    chmod +x /ssl_ca/open_port.sh
    /ssl_ca/open_port.sh add 80
    mkdir -p /var/www/acme
    wget -O $detect_conf_path/acme.conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/domain_http.conf
    sed -i "s|domain|$domains|g" $detect_conf_path/acme.conf
    restart_nginx_openresty
    certbot certonly  \
      --webroot \
      --webroot-path /var/www/acme \
      --email "$selected_email" \
      --agree-tos \
      --key-type rsa \
      --server "$server_url" \
      --non-interactive \
      "${domain_args[@]}"
    rm $detect_conf_path/acme.conf
    /ssl_ca/open_port.sh del 80
    restart_nginx_openresty
    mkdir -p /ssl_ca/hooks
    cat > /ssl_ca/hooks/certbot_pre.sh <<'EOF'
#!/bin/bash
/ssl_ca/open_port.sh add 80
EOF
    cat > /ssl_ca/hooks/certbot_post.sh <<EOF
#!/bin/bash
/ssl_ca/open_port.sh del 80
$reload_cmd
EOF
    chmod +x /ssl_ca/hooks/certbot_*.sh
    (crontab -l 2>/dev/null | grep -v 'certbot renew'; echo '0 3 * * * certbot renew --quiet --pre-hook "/ssl_ca/hooks/certbot_pre.sh" --post-hook "/ssl_ca/hooks/certbot_post.sh"') | crontab -
    echo "已加入自動續訂任務（每天凌晨3點）"

      # 啟動 crond
      case $system in
        1)
          systemctl enable cron
          systemctl start cron
          ;;
        2)
          systemctl enable crond
          systemctl start crond
          ;;
        3)
          rc-update add crond default
          rc-service crond start
          ;;
      esac
  fi

  if [ "$system" -eq 3 ]; then
    reload_cmd="service nginx restart"
  else
    reload_cmd="systemctl reload nginx || true"
  fi
}

toggle_httpguard_module() {
  local module_name=$1
  local current_state=$2
  local config_file

  case $system in
    1|2)
      config_file="/usr/local/openresty/nginx/conf/HttpGuard/config.lua"
      ;;
    3)
      config_file="/etc/nginx/HttpGuard/config.lua"
      ;;
  esac

  if [ ! -f "$config_file" ]; then
    echo "錯誤：HttpGuard/config.lua 未找到。請確認安裝目錄或文件路徑。"
    return 1
  fi

  local new_state=""
  if [ "$current_state" = "On" ]; then
    new_state="Off"
  elif [ "$current_state" = "Off" ]; then
    new_state="On"
  else
    echo "錯誤：無法識別的當前狀態 '$current_state'。"
    return 1
  fi

  echo "正在將模組 [$module_name] 的狀態從 [$current_state] 切換為 [$new_state]..."

  # 使用 sed 替換 config.lua 中的狀態
  # 這裡使用一個更精確的 regex，確保只替換指定模組的 state 值
  sed -i "/^\s*${module_name}\s*=/ s/state\s*=\s*\"[^\"]*\"/state = \"$new_state\"/" "$config_file"

  if [ $? -eq 0 ]; then
    echo "✅ 模組 [$module_name] 狀態已更新為 [$new_state]。"
    echo "正在重啟 Nginx/OpenResty 以應用變更..."
    restart_nginx_openresty
    if [ $? -eq 0 ]; then
      echo "✅ Nginx/OpenResty 已重啟成功。"
    else
      echo "❌ Nginx/OpenResty 重啟失敗，請手動檢查配置。"
    fi
  else
    echo "❌ 更新模組 [$module_name] 狀態失敗。"
  fi
}

update_certbot(){
  case $system in
    1)
      snap refresh certbot > /dev/null 2>&1
      ;;
    2)
      python3 -m pip install --upgrade certbot certbot-nginx certbot-dns-cloudflare --break-system-packages > /dev/null 2>&1
      ;;
    3)
      python3 -m pip install --upgrade certbot certbot-nginx certbot-dns-cloudflare --break-system-packages > /dev/null 2>&1
      ;;
  esac
}
update_script() {
  local download_url="https://gitlab.com/gebu8f/sh/-/raw/main/nginx/ng.sh"
  local temp_path="/tmp/ng.sh"
  local current_script="/usr/local/bin/site"
  local current_path="$0"

  echo "🔍 正在檢查更新..."
  wget -q "$download_url" -O "$temp_path"
  if [ $? -ne 0 ]; then
    echo "❌ 無法下載最新版本，請檢查網路連線。"
    return
  fi

  # 比較檔案差異
  if [ -f "$current_script" ]; then
    if diff "$current_script" "$temp_path" >/dev/null; then
      echo "✅ 腳本已是最新版本，無需更新。"
      rm -f "$temp_path"
      return
    fi
    echo "📦 檢測到新版本，正在更新..."
    cp "$temp_path" "$current_script" && chmod +x "$current_script"
    if [ $? -eq 0 ]; then
      echo "✅ 更新成功！將自動重新啟動腳本以套用變更..."
      sleep 1
      exec "$current_script"
    else
      echo "❌ 更新失敗，請確認權限。"
    fi
  else
    # 非 /usr/local/bin 執行時 fallback 為當前檔案路徑
    if diff "$current_path" "$temp_path" >/dev/null; then
      echo "✅ 腳本已是最新版本，無需更新。"
      rm -f "$temp_path"
      return
    fi
    echo "📦 檢測到新版本，正在更新..."
    cp "$temp_path" "$current_path" && chmod +x "$current_path"
    if [ $? -eq 0 ]; then
      echo "✅ 更新成功！將自動重新啟動腳本以套用變更..."
      sleep 1
      exec "$current_path"
    else
      echo "❌ 更新失敗，請確認權限。"
    fi
  fi

  rm -f "$temp_path"
}

uninstall_nginx(){
  check_web_server
  if [ $openresty -eq 1 ]; then
    case $system in
    1|2)
      systemctl disable openresty
      ;;
    3)
      rc-update del openresty default
      ;;
    esac
    service openresty stop
    case $system in
    1) apt remove openresty ;;
    2) yum remove openresty ;;
    3) apk del openresty ;;
    esac
    pkill -f openresty
    pkill -f nginx
    unlink /etc/nginx
    unlink /usr/sbin/nginx
  elif [ $nginx -eq 1 ]; then
    case $system in
    1|2)
      systemctl disable nginx
      ;;
    3)
      rc-update del nginx default
      ;;
    esac
    service nginx stop
    case $system in
    1) apt remove nginx ;;
    2) yum remove nginx ;;
    3)
      apk del nginx
      rm -rf /etc/init.d/nginx
    ;;
    esac
    local nginx_path=$(command -v nginx)
    if [ -n $nginx_path ]; then
      rm -rf $nginx_path
    fi
    pkill -f nginx
  fi
}



wordpress_site() {
  local MY_IP=$(curl -s https://api64.ipify.org)
  local HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 3 https://wordpress.org)
  local ngx_user=$(get_nginx_run_user)

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "您的IP地址支持訪問 WordPress。"
  else
    echo "您的IP地址不支持訪問 WordPress。"
  # 如果IP看起來像IPv6格式(簡單判斷包含冒號)
    if [[ "$MY_IP" == *:* ]]; then
      echo "您目前是 IPv6，請使用 WARP 等方式將流量轉為 IPv4 以正常訪問 WordPress。"
    fi
    return 1
  fi
  if ! command -v mysql &>/dev/null; then
    echo "MySQL 未安裝，正在安裝..."
    bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/db/install.sh)
    myadmin install
    
    read -p "操作完成，請按任意鍵繼續" -n1
  fi
  echo
  read -p "請輸入您的 WordPress 網址（例如 wp.example.com）：" domain

  # 自動申請 SSL（若不存在）
  check_cert "$domain" || {
    echo "未偵測到 Let Encrypt 憑證，嘗試自動申請..."
    if ssl_apply "$domain"; then
      echo "申請成功，重新驗證憑證..."
        check_cert "$domain" || {
          echo "申請成功但仍無法驗證憑證，中止建立站點"
          return 1
        }
    else
      echo "SSL 申請失敗，中止建立站點"
      return 1
    fi
  }

  # MySQL 自動登入邏輯
  mysql_cmd="mysql -uroot"
  if ! $mysql_cmd -e ";" &>/dev/null; then
    if [ -f /etc/mysql-pass.conf ]; then
      mysql_root_pass=$(cat /etc/mysql-pass.conf)
      mysql_cmd="mysql -uroot -p$mysql_root_pass"
    else
      read -s -p "請輸入 MySQL root 密碼：" mysql_root_pass
      echo
      mysql_cmd="mysql -uroot -p$mysql_root_pass"
    fi
    if ! $mysql_cmd -e ";" &>/dev/null; then
      echo "無法登入 MySQL，請確認密碼正確。"
      return 1
    fi
  fi
  read -p "是否還原現有的wp文件？(Y/N): " restore_file
  restore_file=${restore_file,,}
  if [[ $restore_file == "y" || $restore_file == "" ]]; then
    restore_wp_file "$domain" wp
    return 0
  fi
  # 下載 WordPress 並部署
  mkdir -p "/var/www/$domain"
  curl -L https://wordpress.org/latest.zip -o /tmp/wordpress.zip
  unzip /tmp/wordpress.zip -d /tmp
  mv /tmp/wordpress/* "/var/www/$domain/"

  db_name="wp_${domain//./_}"
  db_user="${db_name}_user"
  db_pass=$(openssl rand -hex 12)

  $mysql_cmd -e "CREATE DATABASE $db_name DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  $mysql_cmd -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
  $mysql_cmd -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
  $mysql_cmd -e "FLUSH PRIVILEGES;"

  # 設定 wp-config.php
  cp "/var/www/$domain/wp-config-sample.php" "/var/www/$domain/wp-config.php"
  sed -i "s/database_name_here/$db_name/" "/var/www/$domain/wp-config.php"
  sed -i "s/username_here/$db_user/" "/var/www/$domain/wp-config.php"
  sed -i "s/password_here/$db_pass/" "/var/www/$domain/wp-config.php"
  sed -i "s/localhost/localhost/" "/var/www/$domain/wp-config.php"
  # 設定權限
  chown -R $ngx_user:$ngx_user "/var/www/$domain"
  setup_site "$domain" php
  read -p "是否要導入現有 SQL 資料？(Y/N): " import_sql
  import_sql=${import_sql,,}
  if [[ $import_sql == "y" || $import_sql == "" ]]; then
    restore_wp_db "$db_name"
    return 0
  fi
  echo "WordPress 網站 $domain 建立完成！請瀏覽 https://$domain 開始安裝流程。"
}

# 菜單

menu_httpguard(){
  clear
  echo "HttpGuard管理"
  echo "-------------------"
  show_httpguard_status
  echo "-------------------"
  echo "1. 開啟/關閉 302 重定向 (redirectModules)"
  echo "2. 開啟/關閉 JS 跳轉 (JsJumpModules)"
  echo "3. 開啟/關閉 Cookie 認證 (cookieModules)"
  echo "4. 開啟/關閉 自動開啟主動防禦 (autoEnable)"
  echo "5. 卸載 HttpGuard"
  echo "0. 退出"
  echo -n -e "\033[1;33m請選擇操作 [0-5]: \033[0m"
  read -r choice
  case $choice in
    1)
      local current_state=$(get_module_state "redirectModules")
      toggle_httpguard_module "redirectModules" "$current_state"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    2)
      local current_state=$(get_module_state "JsJumpModules")
      toggle_httpguard_module "JsJumpModules" "$current_state"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    3)
      local current_state=$(get_module_state "cookieModules")
      toggle_httpguard_module "cookieModules" "$current_state"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    4)
      local current_state=$(get_module_state "autoEnable")
      toggle_httpguard_module "autoEnable" "$current_state"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    5)
    sed -i '/HttpGuard\/init.lua\|HttpGuard\/runtime.lua\|lua_package_path\|lua_package_cpath\|lua_shared_dict guard_dict\|lua_shared_dict dict_captcha\|lua_max_running_timers/d' /etc/nginx/nginx.conf
    rm -rf "/etc/nginx/HttpGuard"
    restart_nginx_openresty
    echo "HttpGuard 卸載完成。"
    read -p "操作完成，請按任意鍵繼續..." -n1
    ;;
    0)
      return 0
      ;;
    *)
      echo "無效的選擇，請重新輸入。"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
  esac
}

menu_add_sites(){
  clear
  echo "新增站點"
  echo "-------------------"
  echo "1. 添加站點（HTML）"
  echo ""
  echo "2. 反向代理"
  echo "-------------------"
  echo "0. 退出"
  echo -n -e "\033[1;33m請選擇操作 [0-2]: \033[0m"
  read -r choice
  case $choice in
    1)
      html_sites
      ;;
    2)
      reverse_proxy
      ;;
    0)
      return 0
      ;;
    *)
      echo "無效選擇。"
  esac
}

menu_del_sites(){

  read -p "請輸入要刪除的網址：" domain
  domain="$(echo $domain | xargs)"  # 去除多餘空白
  local conf_file=$(detect_conf_path)/$domain.conf

  local is_wp_site=false
  local is_flarum_site=false

  if [ -f "/var/www/$domain/wp-config.php" ]; then
    is_wp_site=true
  elif [ -f "/var/www/$domain/config.php" ]; then
    is_flarum_site=true
  fi

  # 吊銷 SSL
  menu_ssl_revoke "$domain" || {
    echo "吊銷 SSL 證書失敗，停止後續操作。"
    return 1
  }

  # 刪除 Nginx 配置與網站資料夾
  rm -rf "$conf_file"
  rm -rf "/var/www/$domain"

  # MySQL root 登入邏輯
  if command -v mysql >/dev/null 2>&1; then
    mysql_cmd="mysql -uroot"
    if ! $mysql_cmd -e ";" &>/dev/null; then
      if [ -f /etc/mysql-pass.conf ]; then
        mysql_root_pass=$(cat /etc/mysql-pass.conf)
        mysql_cmd="mysql -uroot -p$mysql_root_pass"
      else
        read -s -p "請輸入 MySQL root 密碼：" mysql_root_pass
        echo
        mysql_cmd="mysql -uroot -p$mysql_root_pass"
      fi
        if ! $mysql_cmd -e ";" &>/dev/null; then
        echo "MySQL 密碼錯誤，無法刪除資料庫與使用者。"
        return 1
      fi
    fi
  fi

  # 刪除資料庫（依網站類型判斷）
  if [ "$is_wp_site" = true ]; then
    db_name="wp_${domain//./_}"
    db_user="${db_name}_user"
    echo "正在刪除 WordPress 資料庫與使用者..."
  elif [ "$is_flarum_site" = true ]; then
    db_name="flarum_${domain//./_}"
    db_user="${db_name}_user"
    echo "正在刪除 Flarum 資料庫與使用者..."
  fi

  if [ "$is_wp_site" = true ] || [ "$is_flarum_site" = true ]; then
    $mysql_cmd -e "DROP DATABASE IF EXISTS $db_name;"
    $mysql_cmd -e "DROP USER IF EXISTS '$db_user'@'localhost';"
    $mysql_cmd -e "FLUSH PRIVILEGES;"
  fi

  # 重啟 nginx
  restart_nginx_openresty

  echo "已刪除 $domain 站點${is_wp_site:+（含 WordPress 資料庫）}${is_flarum_site:+（含 Flarum 資料庫）}。"
}

menu_ssl_apply() {
  echo "SSL 申請"
  echo "-------------------"
  echo "1. 申請 Certbot(Let's Encrypt、ZeroSSL、Google) 憑證"
  echo ""
  echo "2. 申請 Cloudflare 原始憑證"
  echo "-------------------"
  echo "0. 返回"
  read -p "請選擇: " ssl_choice
  case "$ssl_choice" in
    1) 
      ssl_apply
      ;;
    2) 
      cf_cert_autogen
      ;;
    0) return ;;
  esac
}



menu_ssl_revoke() {
  local cert_dir="/etc/letsencrypt/live"
  local domain="$1"
  if [ -z "$domain" ]; then
    read -p "請輸入要吊銷憑證的域名: " domain
  fi

  # 先取得 cert_info 與 cert_path
  local cert_info=$(check_cert "$domain")
  if [ $? -ne 0 ]; then
    echo "憑證檢查失敗: $cert_info"
    return 1
  fi

  local cert_path="/etc/letsencrypt/live/$cert_info/cert.pem"
  if [ ! -f "$cert_path" ]; then
    echo "找不到憑證檔案: $cert_path"
    return 1
  fi

  echo "正在解析憑證 [$cert_info] 中的 SAN 項目："
  openssl x509 -in "$cert_path" -noout -text | grep -A1 "Subject Alternative Name"
  echo
  echo "確定要吊銷憑證 [$domain] 嗎？（y/n）"
  read -p "選擇：" confirm
  [[ "$confirm" != "y" ]] && echo "已取消。" && return 0


  # 檢查憑證內容是否包含 Cloudflare 字樣
  if openssl x509 -in "$cert_path" -noout -subject | grep -i -q "CloudFlare Origin Certificate"; then
    cf_cert_revoke "$cert_info" || return 1
    return 0
  fi

  echo "檢查和更新cerbot"
  check_certbot
  update_certbot
  
  echo "正在吊銷憑證 $cert_info..."
  certbot revoke --cert-path "$cert_path" --non-interactive --quiet && echo "已吊銷憑證"

  echo
  echo "是否刪除憑證檔案 [$cert_info]？（y/n）"
  read -p "選擇：" delete_choice
  if [[ "$delete_choice" == "y" ]]; then
    rm -rf "$cert_dir/$cert_info"
    rm -rf "/etc/letsencrypt/archive/$cert_info"
    rm -f "/etc/letsencrypt/renewal/$cert_info.conf"
    echo "已刪除憑證資料夾"

    if [ -z "$(find "$cert_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
      if crontab -l 2>/dev/null | grep -q "certbot renew"; then
        crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
        echo "已移除自動續訂任務"
      fi
    fi
  fi
}
menu_wp(){
  while true; do
  clear
  echo "WordPress站點"
  echo "-------------------"
  detect_sites WordPress
  echo "-------------------"
  echo "WordPress管理"
  echo -e "${YELLOW}1. 部署WordPress站點${RESET}"
  echo ""
  echo "2. 安裝插件         3. 移除插件"
  echo ""
  echo "4. 部署主題         5. 移除主題"
  echo ""
  echo "6. 修改管理員帳號   7. 修改管理員密碼"
  echo ""
  echo -e "${YELLOW}8. 修復網站崩潰（禁用所有插件和恢復預設主題，慎用）${RESET}"
  echo ""
  echo "0. 返回"
  echo -n -e "\033[1;33m請選擇操作 [0-10]: \033[0m"
    read -r choice
    case $choice in
    0)
      break
      ;;
    1)
      wordpress_site
      ;;
    2)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      install_wp_plugin_with_search_or_url $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    3)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      remove_wp_plugin_with_menu $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    4)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      deploy_or_remove_theme  install $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    5)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      deploy_or_remove_theme  remove $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    6)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      change_wp_admin_username $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    7)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      change_wp_admin_password $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    8)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      reset_wp_site $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    esac
done
}

menu_restore_site() {
  echo "還原工具"
  echo ""
  echo "1. 還原文件(含SQL)"
  echo ""
  echo "2. 還原SQL"
  echo "-------------------"
  echo "0. 返回"
  echo -n -e "\033[1;33m請選擇操作 [0-2]: \033[0m"
  read -r choice
  case $choice in
  1)
    echo "1. WordPress"
    echo ""
    echo "2. Flarum"
    echo -n -e "\033[1;33m請選擇操作 [0-2]: \033[0m"
    read -r choice
    case $choice in
    1)
      read -p "請輸入需要恢復的域名:" domain
      restore_site_files wp $domain
      ;;
    2)
      read -p "請輸入需要恢復的域名:" domain
      restore_site_files flarum $domain
      ;;
    esac
    ;;
  2)
    echo "1. WordPress"
    echo ""
    echo "2. Flarum"
    echo -n -e "\033[1;33m請選擇操作 [0-2]: \033[0m"
    read -r choice
    case $choice in
    1)
      read -p "請輸入需要恢復的域名:" domain
      restore_site_db wp $domain
      ;;
    2)
      read -p "請輸入需要恢復的域名:" domain
      restore_site_db flarum $domain
      ;;
    esac
  esac
}

menu_php() {
  while true; do
    clear
    show_php
    echo "-------------------"
    echo "PHP管理"
    echo ""
    echo "1. 安裝php              2. 升級/降級php"
    echo ""
    echo "3. 新增普通PHP站點      4. WordPress管理"
    echo ""
    echo "5. 部署flarum站點"
    echo ""
    echo "6. 設定php上傳大小值     7. 安裝php擴展"
    echo ""
    echo "8. 安裝Flarum擴展       9. 管理HttpGuard"
    echo
    echo "10. 備份網站            11. 還原網站 "
    echo ""
    echo "12. 安裝phpmyadmin"
    echo ""
    echo "r. PHP一鍵配置（設定www配置文件至我腳本可用之狀態）"
    echo "-------------------"
    echo "0. 返回"
    echo -n -e "\033[1;33m請選擇操作 [0-12]: \033[0m"
    read -r choice
    case $choice in
      1)
        clear
        php_install || read -p "操作完成，請按任意鍵繼續..." -n1 && return
        php_fix
        
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      2) 
        clear
        check_php
        php_switch_version
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      3)
        clear
        check_php
        local ngx_user=$(get_nginx_run_user)
        read -p "請輸入您的域名：" domain
        check_cert "$domain" || {
          echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
          if ssl_apply "$domain"; then
            echo "申請成功，重新驗證憑證..."
              check_cert "$domain" || {
                echo "申請成功但仍無法驗證憑證，中止建立站點"
                return 1
              }
          else
            echo "SSL 申請失敗，中止建立站點"
            return 1
          fi
        }
        mkdir -p /var/www/$domain
        read -p "是否自訂index.php文件(Y/n)?" confirm
        confirm=${confirm,,}
        if [[ "$confirm" == "y" || "$confirm" == "" ]]; then
          nano /var/www/$domain/index.php
        else
          echo "<?php echo 'Hello from your PHP site!'; ?>" > "/var/www/$domain/index.php"
        fi
        chown -R $ngx_user:$ngx_user "/var/www/$domain"
        setup_site "$domain" php
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      4)
        clear
        check_php
        menu_wp
        ;;
      5)
        clear
        check_php
        flarum_setup
        read -p "按任意鍵繼續..." -n1
        ;;
      6)
        clear
        check_php
        php_tune_upload_limit
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      7)
        check_php
        php_install_extensions
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      8)
        check_php
        flarum_extensions
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      9)
        httpguard_setup
        ;;
      10)
        echo "備份工具"
        echo ""
        echo "1. 一般備份"
        echo "2. 移除已設定的自動備份排程"
        read -p "請選擇[1-2]：" choice
        case $choice in
        1)
          backup_site
          ;;
        2)
          backup_cron_remove
          ;;
        esac
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      11)
        menu_restore_site
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      12)
        install_phpmyadmin
        ;;
      r)
        php_fix
        ;;
        
      0)
        break
        ;;
      *)
        echo "無效的選擇，請重新輸入。"
        ;;
    esac
  done
}

#主菜單
show_menu(){
  show_cert_status
  echo "-------------------"
  echo "站點管理器"
  echo ""
  echo -e "${YELLOW}i. 安裝或重裝 Nginx / OpenResty          r. 解除安裝 Nginx / OpenResty${RESET}"
  echo ""
  echo "1. 新增站點           2. 刪除站點"
  echo ""
  echo "3. 申請 SSL 證書      4. 刪除 SSL 證書"
  echo ""
  echo "5. 切換 Certbot 廠商  6. PHP 管理"
  echo ""
  echo "u. 更新腳本           0. 離開"
  echo "-------------------"
  echo -n -e "\033[1;33m請選擇操作 [1-6 / i u 0]: \033[0m"
}

case "$1" in
  --version|-V)
    echo "站點管理器版本 6.1.1"
    exit 0
    ;;
esac

# 只有不是 --version 或 -V 才會執行以下初始化
check_system
check_app
check_web_environment
check_nginx_start
check_and_start_service
check_web_server

case "$1" in
  setup)
    domain="$2"
    site_type="$3"

    if [[ -z "$domain" || -z "$site_type" ]]; then
      echo "用法錯誤: bash ng.sh setup_site <domain> <type>"
      echo "或 proxy 類型: bash ng.sh setup_site <domain> proxy <url> <protocol> <port>"
      exit 1
    fi

    echo "正在處理站點: $domain (類型: $site_type)"

    # 申請 SSL 憑證
    if ssl_apply "$domain"; then
      echo "SSL 申請成功，驗證憑證..."
      check_cert "$domain" || {
        echo "憑證驗證失敗，中止建立站點"
        exit 1
      }
    else
      echo "SSL 申請失敗，中止建立站點"
      exit 1
    fi

    case "$site_type" in
      html|flarum|php)
        setup_site "$domain" $site_type
        ;;
      proxy)
        target_url="$4"
        target_proto="$5"
        target_port="$6"

        if [[ -z "$target_url" || -z "$target_proto" || -z "$target_port" ]]; then
          echo "proxy 類型需要提供 target_url protocol port"
          exit 1
        fi

        setup_site "$domain" proxy "$target_url" "$target_proto" "$target_port"
        ;;
    esac
    exit 0
    ;;
esac


# 主循環
while true; do
  conf_file=""
  clear
  show_menu
  read -r choice
  case $choice in
    i)
      check_web_environment
      check_nginx
      check_web_server
      ;;
    1)
      check_no_ngx || continue
      menu_add_sites
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    2)
      check_no_ngx || continue
      menu_del_sites 
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    3)
      menu_ssl_apply
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    4)
      menu_ssl_revoke
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    5)
      check_certbot
      update_certbot
      select_ca
      ;;
    6)
      check_no_ngx || continue
      menu_php
      ;;
    0)
      exit 0
      ;;
    u)
      clear
      echo "更新腳本"
      echo "------------------------"
      update_script
      ;;
    r)
      uninstall_nginx
      ;;
    *)
      echo "無效選擇。"
  esac
done
