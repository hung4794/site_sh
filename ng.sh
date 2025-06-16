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

check_cert() {
  local domain="$1"
  local cert_dir="/etc/letsencrypt/live"
  local domain_parts=($(echo "$domain" | tr '.' ' '))
  local level=${#domain_parts[@]}


  if [ "$level" -gt 6 ]; then
    echo "網域層級過多（$level），請檢查輸入是否正確。"
    return 1
  fi

  while [ "$level" -ge 2 ]; do
    local base_domain=$(printf ".%s" "${domain_parts[@]: -$level}")
    base_domain=${base_domain:1}
    local cert_path="$cert_dir/$base_domain/fullchain.pem"

    if [ -f "$cert_path" ]; then
      local san_list=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null | \
        grep -oE 'DNS:[^,]+' | sed 's/DNS://g')

      for san in $san_list; do
        if [[ "$san" == "$domain" ]] || [[ "$san" == "*.${domain#*.}" ]]; then
          echo "$base_domain"
          return 0
        fi
      done
    fi

    ((level--))
  done

  echo "未找到包含 $domain 的有效憑證"
  return 1
}

#檢查nginx
check_nginx(){
  declare -a servers=("apache2" "caddy" "lighttpd" "boa")

  for svc in "${servers[@]}"; do
    if command -v "$svc" >/dev/null 2>&1; then
      echo "偵測到已安裝的 Web 伺服器：$svc"
      read -p "是否要解除安裝 $svc？[y/N]: " yn
      if [[ $yn =~ ^[Yy]$ ]]; then
        case "$system" in
        1) apt remove -y $svc ;;
        2) yum remove -y $svc ;;
        3) apk del $svc ;;
        esac
      else
        echo "保留 $svc。退出腳本..."
        exit 1
      fi
    fi
  done
  if ! command -v nginx >/dev/null 2>&1 && ! command -v openresty >/dev/null 2>&1; then
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
  case $system in
    1|2)
      mkdir -p /run/php
      chown -R nginx:nginx /run/php
      chmod 755 /run/php
      ;;
    3)
      mkdir -p /run/php
      chown nginx:nginx /run/php
      chmod 755 /run/php
      rc-service php-fpm83 restart
      ;;
  esac
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

default(){
  create_directories
  generate_ssl_cert
  case "$system" in
  1|2)
    rm -f /etc/nginx/conf.d/default.conf
    wget -O /etc/nginx/conf.d/default.conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/default_system
    rm -f /etc/nginx/nginx.conf
    wget -O /etc/nginx/nginx.conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/nginx.conf
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
    rm -f /etc/nginx/conf.d/default.conf
    rm -f /etc/nginx/nginx.conf
    wget -O /etc/nginx/nginx.conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/nginx.conf
    sed -i 's|^#\s*pid\s\+/run/nginx.pid;|pid /run/nginx.pid;|' /etc/nginx/nginx.conf
    wget -O /etc/nginx/conf.d/default.conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/default_system
    id -u nginx &>/dev/null || adduser -D -H -s /sbin/nologin nginx
    rc-service nginx restart
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

flarum_setup() {
  local php_var=$(check_php_version)
  local supported_php_versions=$(check_flarum_supported_php)
  local max_supported_php=$(echo "$supported_php_versions" | tr ' ' '\n' | sort -V | tail -n1)

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
    if menu_ssl_apply "$domain"; then
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
  db_pass=$(openssl rand -base64 12)

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

  chown -R nginx:nginx "/var/www/$domain"
  setup_site "$domain" flarum

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

html_sites(){
  read -p "請輸入網址:" domain
  check_cert "$domain" || {
    echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
    if menu_ssl_apply "$domain"; then
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
  chown -R nginx:nginx /var/www/$domain
  setup_site "$domain" html
  echo "已建立 $domain 之html站點。"
}
httpguard_setup(){
  check_php
  case $system in
  1|2)
    if ! command -v openresty &>/dev/null; then
      echo "未偵測到 openresty 指令，請先安裝 OpenResty。"
      return 1
    fi
    if ! openresty -V 2>&1 | grep -iq lua; then
      echo "您的 OpenResty 不支援 Lua 模組，無法使用 HttpGuard。"
      return 1
    fi
    local ngx_conf="/usr/local/openresty/nginx/conf/nginx.conf"
    local guard_dir="/usr/local/openresty/nginx/conf/HttpGuard"
    ;;
  3)
    if ! command -v nginx &>/dev/null; then
      echo "未偵測到 nginx 指令，請先安裝 nginx。"
      return 1
    fi
    if ! nginx -V 2>&1 | grep -iq lua; then
      echo "您的 OpenResty 不支援 Lua 模組，無法使用 HttpGuard。"
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
    case $system in
    1|2)
      service openresty restart || service nginx restart
      ;;
    3)
      rc-service nginx restart
      ;;
    esac
    echo "HttpGuard 安裝完成"
    menu_httpguard
  else
    echo "安裝失敗.."
    return 1
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
        php$phpver-xml php$phpver-mbstring php$phpver-zip php$phpver-intl php$phpver-bcmath php$phpver-imagick unzip

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
      yum install -y php php-fpm php-mysqlnd php-curl php-gd php-xml php-mbstring php-zip php-intl php-bcmath php-pecl-imagick unzip

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
        php$shortver-intl php$shortver-bcmath php$shortver-pecl-imagick unzip || {
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
  if [ $system -eq 1 ]; then
    sed -i -r 's|^;?(user\s*=\s*).*|\1nginx|' /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r 's|^;?(group\s*=\s*).*|\1nginx|' /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r 's|^;?(listen.owner\s*=\s*).*|\1nginx|' /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r 's|^;?(listen.group\s*=\s*).*|\1nginx|' /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r 's|^;?(listen.mode\s*=\s*).*|\10660|' /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r 's|^;?(listen\s*=\s*).*|\1/run/php/php-fpm.sock|' /etc/php/$php_var/fpm/pool.d/www.conf
    chown_set
    systemctl restart php$php_var-fpm
  elif [ $system -eq 2 ]; then
    sed -i 's/^user =.*/user = nginx/' /etc/php-fpm.d/www.conf
    sed -i 's/^group =.*/group = nginx/' /etc/php-fpm.d/www.conf
    sed -i 's/^;listen.owner =.*/listen.owner = nginx/' /etc/php-fpm.d/www.conf
    sed -i 's/^;listen.group =.*/listen.group = nginx/' /etc/php-fpm.d/www.conf
    sed -i 's|^listen =.*|listen = /run/php/php-fpm.sock|' /etc/php-fpm.d/www.conf
    sed -i 's/^;listen.mode =.*/listen.mode = 0660/' /etc/php-fpm.d/www.conf
    chown_set
    systemctl restart php-fpm
  elif [ $system -eq 3 ]; then
    sed -i 's/^user =.*/user = nginx/' /etc/php$php_var/php-fpm.d/www.conf
    sed -i 's/^group =.*/group = nginx/' /etc/php$php_var/php-fpm.d/www.conf
    sed -i 's|^listen =.*|listen = /run/php/php-fpm.sock|' /etc/php$php_var/php-fpm.d/www.conf
    sed -i 's/^;listen.owner =.*/listen.owner = nginx/' /etc/php$php_var/php-fpm.d/www.conf
    sed -i 's/^;listen.group =.*/listen.group = nginx/' /etc/php$php_var/php-fpm.d/www.conf
    sed -i 's/^;listen.mode =.*/listen.mode = 0660/' /etc/php$php_var/php-fpm.d/www.conf
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
    if menu_ssl_apply "$domain"; then
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
  case $system in
    1|2)
      service openresty restart || service nginx restart
      ;;
    3)
      rc-service nginx restart
      ;;
  esac
}

setup_site() {
  local domain=$1
  local type=$2
  local domain_cert=$(check_cert "$domain" | tail -n 1 | tr -d '\r\n')
  local escaped_cert=$(printf '%s' "$domain_cert" | sed 's/[&/\]/\\&/g') # 取得主域名或泛域名作為憑證目錄
  echo "$domain_cert"

  case $system in
    1|2)
      case $type in
        html|php|www|flarum)
          local conf_url="https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/donain_${type}.conf"
          local conf_path="/etc/nginx/conf.d/$domain.conf"
          wget -O "$conf_path" "$conf_url"
          sed -i "s|domain|$domain|g" "$conf_path"
          
          sed -i "s|main|$escaped_cert|g" "$conf_path"

          if nginx -t; then
            systemctl restart openresty
          else
            echo "nginx 測試失敗，請檢查配置"
            return 1
          fi
          ;;
        proxy)
          local target_url=$3
          local target_protocol=$4
          local target_port=$5
          wget -O /etc/nginx/conf.d/$domain.conf https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/domain_proxy.conf
          sed -i "s|proxy_pass host:port;|proxy_pass $target_protocol://$target_url:$target_port;|g" /etc/nginx/conf.d/$domain.conf
          sed -i "s|domain|$domain|g" /etc/nginx/conf.d/$domain.conf
          sed -i "s|main|$escaped_cert|g" /etc/nginx/conf.d/$domain.conf
          if nginx -t; then
            systemctl restart openresty
          else
            echo "nginx測試失敗"
            return 1
          fi
          ;;
          
        *)
          echo "不支援的類型: $type"; return 1;;
      esac
      ;;
    3)
      case $type in
        php|flarum|www|html)
          local conf_url="https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/donain_${type}.conf"
          local conf_path="/etc/nginx/conf.d/$domain.conf"
          wget -O $conf_path $conf_url
          sed -i "s|domain|$domain|g" "$conf_path"
          sed -i "s|main|$escaped_cert|g" $conf_path
          
          if nginx -t; then
            rc-service nginx restart
          else
            echo "nginx測試失敗"
            return 1
          fi
          ;;
        proxy)
          local target_url=$3
          local target_protocol=$4
          local target_port=$5
          wget -O /etc/nginx/conf.d/$domain.conf https://raw.githubusercontent.com/gebu8f8/site_sh/refs/heads/main/domain_proxy.conf
          sed -i "s|proxy_pass http://host:port;|proxy_pass $target_protocol://$target_url:$target_port;|g" /etc/nginx/conf.d/$domain.conf
          sed -i "s|domain|$domain|g" /etc/nginx/conf.d/$domain.conf
          sed -i "s|main|$escaped_cert|g" /etc/nginx/conf.d/$domain.conf
          if nginx -t; then
            rc-service nginx restart
          else
            echo "nginx測試失敗"
            return 1
          fi
          ;;
        *)
          echo "不支援的類型"; return 1;;
      esac
      ;;
    *) echo "不支援的系統"; return 1;;
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
  echo -e "===== Nginx 站點憑證狀態 ====="
  printf "%-30s | %-20s | %-20s | %s\n" "域名" "到期日" "憑證資料夾" "狀態"
  echo "----------------------------------------------------------------------------------------------"

  local CERT_PATH="/etc/letsencrypt/live"
  local nginx_conf_paths="/etc/nginx/conf.d"

  # 讀取所有 server_name 域名
  local nginx_domains
  nginx_domains=$(grep -rhoE 'server_name\s+[^;]+' "$nginx_conf_paths" 2>/dev/null | \
    sed -E 's/server_name\s+//' | tr ' ' '\n' | grep -E '^[a-zA-Z0-9.-]+$' | sort -u)

  for nginx_domain in $nginx_domains; do
    local matched_cert="-"
    local end_date="無憑證"
    local status=$'\e[31m未使用/錯誤\e[0m'

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
            # 如果還沒找到泛域名憑證就記錄
            if [[ -z "$wildcard_match_cert" ]]; then
              wildcard_match_cert=$(basename "$cert_dir")
              wildcard_match_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
            fi
          fi
        fi
      done
    done

    # 優先使用精確匹配，其次泛域名
    if [[ -n "$exact_match_cert" ]]; then
      matched_cert="$exact_match_cert"
      end_date="$exact_match_date"
      status="是"
    elif [[ -n "$wildcard_match_cert" ]]; then
      matched_cert="$wildcard_match_cert"
      end_date="$wildcard_match_date"
      status="泛域名命中"
    fi

    printf "%-30s | %-20s | %-20s | %b\n" "$nginx_domain" "$end_date" "$matched_cert" "$status"
  done
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



wordpress_site() {
  local MY_IP=$(curl -s https://api64.ipify.org)
  local HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 3 https://wordpress.org)

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
    if menu_ssl_apply "$domain"; then
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

  db_name="wp_${domain//./_}"
  db_user="${db_name}_user"
  db_pass=$(openssl rand -hex 12)

  $mysql_cmd -e "CREATE DATABASE $db_name DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  $mysql_cmd -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
  $mysql_cmd -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
  $mysql_cmd -e "FLUSH PRIVILEGES;"

  # 下載 WordPress 並部署
  mkdir -p "/var/www/$domain"
  curl -L https://wordpress.org/latest.zip -o /tmp/wordpress.zip
  unzip /tmp/wordpress.zip -d /tmp
  mv /tmp/wordpress/* "/var/www/$domain/"
  
  # 設定 wp-config.php
  cp "/var/www/$domain/wp-config-sample.php" "/var/www/$domain/wp-config.php"
  sed -i "s/database_name_here/$db_name/" "/var/www/$domain/wp-config.php"
  sed -i "s/username_here/$db_user/" "/var/www/$domain/wp-config.php"
  sed -i "s/password_here/$db_pass/" "/var/www/$domain/wp-config.php"
  sed -i "s/localhost/localhost/" "/var/www/$domain/wp-config.php"
  # 設定權限
  chown -R nginx:nginx "/var/www/$domain"
  setup_site "$domain" php
  echo "WordPress 網站 $domain 建立完成！請瀏覽 https://$domain 開始安裝流程。"
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

  echo "正在檢查更新..."
  wget -q "$download_url" -O "$temp_path"
  if [ $? -eq 0 ]; then
    if [ -f "$current_script" ]; then
      if ! diff "$current_script" "$temp_path" &>/dev/null; then
        echo "檢測到新版本，準備更新..."
        chmod +x "$temp_path"
        cp "$temp_path" "$current_script"
        if [ $? -eq 0 ]; then
          echo "更新成功！腳本已更新至最新版本。"
          echo "請重新打開腳本以體驗最新功能"
          read -p "操作完成，請按任意鍵繼續..." -n1
          exit 0
        else
          echo "更新失敗！請檢查權限或手動更新腳本。"
        fi
      else
        echo "腳本已是最新版本，無需更新。"
      fi
    else
      if ! diff "$current_path" "$temp_path" &>/dev/null; then
        echo "檢測到新版本，準備更新..."
        chmod +x "$temp_path"
        cp "$temp_path" "$current_path"
        if [ $? -eq 0 ]; then
          echo "更新成功！腳本已更新至最新版本。"
          read -p "操作完成，請按任意鍵繼續..." -n1
          exit 0
        else
          echo "更新失敗！請檢查權限或手動更新腳本。"
        fi
      else
        echo "腳本已是最新版本，無需更新。"
      fi
    fi
    rm -f "$temp_path"
  else
    echo "無法下載最新版本，請檢查網路連線。"
  fi
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
    case $system in
    1|2)
      service openresty restart
      ;;
    3)
      rc-service nginx restart
      ;;
    esac
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
  rm -rf "/etc/nginx/conf.d/$domain.conf"
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
  if [ $system -eq 1 ] || [ $system -eq 2 ]; then
    systemctl restart openresty
  elif [ $system -eq 3 ]; then
    rc-service nginx restart
  fi

  echo "已刪除 $domain 站點${is_wp_site:+（含 WordPress 資料庫）}${is_flarum_site:+（含 Flarum 資料庫）}。"
}



menu_ssl_apply() {
  check_certbot
  update_certbot
  mkdir -p /ssl_ca

  local domains="$1"
  if [ -z "$domains" ]; then
    read -p "請輸入您的域名（可用逗號分隔）：" domains
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
      --email "$selected_email" \
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
    certbot --nginx \
      --email "$selected_email" \
      --agree-tos \
      --server "$server_url" \
      --non-interactive \
      $domain_args
    /ssl_ca/open_port.sh del 80
    mkdir -p /ssl_ca/hooks
    echo -e "#!/bin/bash\n/ssl_ca/open_port.sh add 80" > /ssl_ca/hooks/certbot_pre.sh
    echo -e "#!/bin/bash\n/ssl_ca/open_port.sh del 80\n$reload_cmd" > /ssl_ca/hooks/certbot_post.sh
    chmod +x /ssl_ca/hooks/certbot_*.sh
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --pre-hook \"/ssl_ca/hooks/certbot_pre.sh\" --post-hook \"/ssl_ca/hooks/certbot_post.sh\"") | crontab -
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
  fi

  if [ "$system" -eq 3 ]; then
    reload_cmd="nginx -s reload"
  else
    reload_cmd="systemctl reload nginx || true"
  fi
}

menu_ssl_revoke() {
  check_certbot
  update_certbot

  local cert_dir="/etc/letsencrypt/live"
  local domain="$1"
  if [ -z "$domain" ]; then
    read -p "請輸入要吊銷憑證的域名: " domain
  fi

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
  echo "確定要吊銷憑證 [$cert_info] 嗎？（y/n）"
  read -p "選擇：" confirm
  [[ "$confirm" != "y" ]] && echo "已取消。" && return 0

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

    if [ -z "$(ls -A "$cert_dir" 2>/dev/null)" ]; then
      if crontab -l 2>/dev/null | grep -q "certbot renew"; then
        crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
        echo "已移除自動續訂任務"
      fi
    fi
  fi
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
    echo "3. 新增普通PHP站點      4. 部署WordPress站點"
    echo ""
    echo "5. 部署flarum站點"
    echo ""
    echo "6. 設定wp上傳大小值     7. 安裝php擴展"
    echo ""
    echo "8. 安裝Flarum擴展       9. 管理HttpGuard"
    echo ""
    echo "-------------------"
    echo "0. 返回"
    echo -n -e "\033[1;33m請選擇操作 [0-9]: \033[0m"
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
        read -p "請輸入您的域名：" domain
        check_cert "$domain" || {
          echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
          if menu_ssl_apply "$domain"; then
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
        confirm=$(confirm,,)
        if [[ "$confirm" == "y" || "$confirm" == "" ]]; then
          nano /var/www/$domain/index.php
        else
          echo "<?php echo 'Hello from your PHP site!'; ?>" > "/var/www/$domain/index.php"
        fi
        chown -R nginx:nginx "/var/www/$domain"
        setup_site "$domain" php
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      4)
        clear
        check_php
        wordpress_site
        read -p "操作完成，請按任意鍵繼續..." -n1
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
  #clear
  show_cert_status
  echo "-------------------"
  echo "站點管理器"
  echo ""
  echo "1. 新增站點           2. 刪除站點"
  echo ""
  echo "3. 申請SSL證書        4. 刪除SSL證書"
  echo ""
  echo "5. 切換certbot申請廠商  6. PHP管理"
  echo "-------------------"
  echo "0. 退出             00. 腳本更新"
  echo -n -e "\033[1;33m請選擇操作 [0-6]: \033[0m"
}

case "$1" in
  --version|-V)
    echo "站點管理器版本 4.3.0"
    exit 0
    ;;
esac

# 只有不是 --version 或 -V 才會執行以下初始化
check_system
check_app
check_nginx

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
    if menu_ssl_apply "$domain"; then
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
  clear
  show_menu
  read -r choice
  case $choice in
    1)
      menu_add_sites
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    2)
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
      menu_php
      ;;
    0)
      exit 0
      ;;
    00)
      clear
      echo "更新腳本"
      echo "------------------------"
      update_script
      ;;
    *)
      echo "無效選擇。"
  esac
done
