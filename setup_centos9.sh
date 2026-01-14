#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/setup_centos9.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

check_error() {
    if [ $? -ne 0 ]; then
        log "ОШИБКА: $1"
        exit 1
    fi
}

load_env() {
    log "Загрузка переменных окружения из .env"
    if [ -f "$SCRIPT_DIR/.env" ]; then
        source "$SCRIPT_DIR/.env"
    else
        log "ОШИБКА: Файл .env не найден в $SCRIPT_DIR"
        exit 1
    fi
}

update_packages() {
    log "Обновление всех пакетов системы"
    dnf update -y
    check_error "Не удалось обновить пакеты"
    log "Пакеты успешно обновлены"
}

install_software() {
    log "Установка необходимого ПО: fail2ban, certbot, ufw, docker-ce, docker compose -plugin, nginx"

    # Удаление Podman и связанных пакетов
    log "Удаление Podman и связанных пакетов"
    dnf remove -y podman podman-docker podman-compose buildah criu || true
    dnf autoremove -y || true
    
    # Очистка конфигурации Podman
    rm -rf /etc/containers/ || true
    rm -f /usr/local/bin/docker compose  || true
    
    dnf install -y dnf-plugins-core
    check_error "Не удалось установить dnf-plugins-core"

    # Добавление официального репозитория Docker
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    check_error "Не удалось добавить репозиторий Docker"

    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    check_error "Не удалось установить Docker CE"

    dnf install -y fail2ban certbot ufw nginx
    check_error "Не удалось установить остальное ПО"

    log "Необходимое ПО успешно установлено"
}

create_user() {
    log "Создание пользователя $NEW_USER_LOGIN"
    
    if id "$NEW_USER_LOGIN" &>/dev/null; then
        log "Пользователь $NEW_USER_LOGIN уже существует"
    else
        useradd -m -s /bin/bash "$NEW_USER_LOGIN"
        check_error "Не удалось создать пользователя $NEW_USER_LOGIN"
        
        echo "$NEW_USER_LOGIN:$NEW_USER_PASSWORD" | chpasswd
        check_error "Не удалось установить пароль для пользователя $NEW_USER_LOGIN"
        
        log "Пользователь $NEW_USER_LOGIN создан"
    fi
    
    usermod -aG wheel "$NEW_USER_LOGIN"
    check_error "Не удалось добавить пользователя $NEW_USER_LOGIN в группу wheel"
    
    log "Пользователь $NEW_USER_LOGIN добавлен в группы wheel и docker"
}

configure_ssh() {
    log "Настройка SSH"
    
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    check_error "Не удалось создать резервную копию sshd_config"
    
    local temp_sshd_config="/tmp/sshd_config_temp"
    if [ -f "$SCRIPT_DIR/sshd_config" ]; then
        sed "s/\$SSH_PORT/$SSH_PORT/g" "$SCRIPT_DIR/sshd_config" | \
        sed "s/\$NEW_USER_LOGIN/$NEW_USER_LOGIN/g" > "$temp_sshd_config"
        
        cp "$temp_sshd_config" /etc/ssh/sshd_config
        check_error "Не удалось скопировать sshd_config"
        rm -f "$temp_sshd_config"
    else
        log "ОШИБКА: Файл sshd_config не найден в $SCRIPT_DIR"
        exit 1
    fi
    
    systemctl restart sshd
    check_error "Не удалось перезапустить SSH службу"
    
    log "SSH настроен. Порт изменен на $SSH_PORT, запрещен вход root и аутентификация по паролю"
}

configure_fail2ban() {
    log "Настройка fail2ban"
    
    if [ -f "$SCRIPT_DIR/fail2ban_jail.local" ]; then
        cp "$SCRIPT_DIR/fail2ban_jail.local" /etc/fail2ban/jail.local
        check_error "Не удалось скопировать fail2ban_jail.local"
    else
        log "ОШИБКА: Файл fail2ban_jail.local не найден в $SCRIPT_DIR"
        exit 1
    fi
    
    sed -i "s/port    = ssh/port    = $SSH_PORT/g" /etc/fail2ban/jail.local
    
    systemctl enable fail2ban
    systemctl start fail2ban
    check_error "Не удалось запустить fail2ban"
    
    log "fail2ban настроен и запущен"
}

configure_ufw() {
    log "Настройка UFW"
    
    systemctl enable ufw
    systemctl start ufw
    
    ufw --force reset
    
    ufw default deny incoming
    ufw default allow outgoing
    
    ufw allow "$SSH_PORT"
    ufw allow "$XRAY_PORT"
    ufw allow "$REMNANODE_PORT"
    ufw allow 80
    echo "y" | ufw enable
    check_error "Не удалось включить UFW"
    
    log "UFW настроен. Разрешены порты: 80, $SSH_PORT, $XRAY_PORT, $REMNANODE_PORT"
}

configure_docker() {
    log "Настройка Docker"
    
    systemctl enable docker
    systemctl start docker
    check_error "Не удалось запустить Docker"
    
    docker --version
    check_error "Docker не работает корректно"
    
    if ! getent group docker > /dev/null; then
        groupadd docker
        log "Группа docker создана"
    fi
    
    usermod -aG docker "$NEW_USER_LOGIN"
    check_error "Не удалось добавить пользователя $NEW_USER_LOGIN в группу docker"
    
    log "Docker CE настроен и запущен, пользователь $NEW_USER_LOGIN добавлен в группу docker"
}

configure_nginx() {
    log "Настройка nginx в Docker"

    local nginx_dir="/opt/nginx"
    local script_nginx_dir="$SCRIPT_DIR/nginx"

    if [ -d "$script_nginx_dir" ]; then
        mkdir -p "$nginx_dir"
        cp -r "$script_nginx_dir"/* "$nginx_dir/"
        check_error "Не удалось скопировать nginx файлы"
    else
        log "ОШИБКА: Директория nginx не найдена в $SCRIPT_DIR"
        exit 1
    fi

    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        log "ОШИБКА: SSL сертификаты не найдены в /etc/letsencrypt/live/$DOMAIN"
        exit 1
    fi

    sed -i -e "s/\$DOMAIN/$DOMAIN/g" \
           "$nginx_dir/nginx.conf" \
           "$nginx_dir/docker-compose.yml"
    check_error "Не удалось настроить конфигурационные файлы"

    mkdir -p /dev/shm/nginx
    chmod 755 /dev/shm/nginx

    cd "$nginx_dir"
    docker compose up -d
    check_error "Не удалось запустить nginx в Docker"

    sleep 3
    if docker compose ps | grep -q "Up"; then
        log "nginx успешно запущен в Docker"
    else
        log "ОШИБКА: nginx не запустился"
        docker compose logs
        exit 1
    fi

    log "nginx настроен. Домен: $DOMAIN"
}

get_ssl_certificates() {
    log "Получение SSL сертификатов для домена $DOMAIN"
    sudo mkdir -p /var/www/certbot
    sudo chmod 755 /var/www/certbot
    sudo chown -R $USER:$USER /var/www/certbot

    certbot certonly --standalone --non-interactive --agree-tos \
        --email $EMAIL \
        -d $DOMAIN \
        --http-01-port 80 \
        --cert-name $DOMAIN

    check_error "Не удалось получить SSL сертификаты для $DOMAIN"
    log "SSL сертификаты для $DOMAIN успешно получены"
}

setup_cert_renewal() {
    log "Настройка скрипта для автоматического обновления сертификатов"
    
    local renew_script="/usr/local/bin/renew_ssl_certificates.sh"
    
    if [ -f "$SCRIPT_DIR/renew_ssl_certificates.sh" ]; then
        cp "$SCRIPT_DIR/renew_ssl_certificates.sh" "$renew_script"
        check_error "Не удалось скопировать renew_ssl_certificates.sh"
    else
        log "ОШИБКА: Файл renew_ssl_certificates.sh не найден в $SCRIPT_DIR"
        exit 1
    fi
    
    chmod +x "$renew_script"
    
    (crontab -l 2>/dev/null | grep -v "$renew_script"; echo "0 3 * * * $renew_script") | crontab -
    check_error "Не удалось добавить задание в cron для обновления сертификатов"
    
    log "Скрипт обновления сертификатов настроен и добавлен в cron (ежедневно в 3:00)"
}

setup_auto_reboot() {
    log "Настройка автоматической перезагрузки в 5:00"
    
    (crontab -l 2>/dev/null | grep -v "reboot"; echo "0 5 * * * /sbin/reboot") | crontab -
    check_error "Не удалось добавить задание перезагрузки в cron"
    
    log "Автоматическая перезагрузка настроена на 5:00 ежедневно"
}

setup_remnanode() {
    log "Настройка RemnaNode"

    local remnanode_dir="/opt/remnanode"
    local script_remnanode_dir="$SCRIPT_DIR/remnanode"

    if [ -d "$script_remnanode_dir" ]; then
        mkdir -p "$remnanode_dir"
        cp -r "$script_remnanode_dir"/* "$remnanode_dir/"
        check_error "Не удалось скопировать файлы RemnaNode"
    else
        log "ОШИБКА: Директория remnanode не найдена в $SCRIPT_DIR"
        exit 1
    fi

    if [ -f "$remnanode_dir/docker-compose.yml" ]; then
        # Заменяем переменные в docker-compose.yml
        sed -i "s/\$REMNANODE_PORT/$REMNANODE_PORT/g" "$remnanode_dir/docker-compose.yml"
        sed -i "s/\$REMNAWAVE_SECRET_KEY/$REMNAWAVE_SECRET_KEY/g" "$remnanode_dir/docker-compose.yml"
        
        log "docker-compose.yml обновлен с актуальными переменными"
    else
        log "ОШИБКА: docker-compose.yml не найден в $remnanode_dir"
        exit 1
    fi

    mkdir -p /var/log/remnanode
    mkdir -p /opt/remnawave/xray/share
    cd "$remnanode_dir"

    # Добавить задачу, сохраняя существующие
    (crontab -l 2>/dev/null; echo "0 2,14 * * * wget -O /opt/remnanode/xray/share/zapret.dat https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat") | crontab -
    log "Настроено обновление томов Zapret RU GOV дважды в день."
    log "Том расположен по пути: /opt/remnanode/xray/share/zapret.dat"

    docker compose up -d
    check_error "Не удалось запустить RemnaNode"

    log "RemnaNode настроен и запущен"
}

print_post_setup_info() {
    echo "================================================"
    echo "✅ RemnaNode успешно настроен и запущен"
    echo "================================================"
    echo ""
    echo "📊 СТАТУС СЕРВИСОВ:"
    echo "   • RemnaNode: $(docker ps --filter "name=remnanode" --format "table {{.Names}}\t{{.Status}}" | grep remnanode) 🟢"
    echo "   • Nginx: $(systemctl is-active nginx) 🟢"
    echo "   • Docker: $(systemctl is-active docker) 🟢"
    echo "   • Xray: $(ss -tlnp | grep ':$XRAY_PORT ' | awk '{print $6}') 🟢"
    echo "   • UFW: $(systemctl is-active ufw) 🟢"
    echo ""
    echo "🌐 СЕТЕВЫЕ НАСТРОЙКИ:"
    echo "   • SSH порт: $SSH_PORT"
    echo "   • RemnaNode порт: $REMNANODE_PORT"
    echo "   • Xray порт: $XRAY_PORT"
    echo "   • Внешний IP: $(curl -s ifconfig.me)"
    echo ""
    echo "🔐 БЕЗОПАСНОСТЬ:"
    echo "   • Пользователь: $NEW_USER_LOGIN"
    echo "   • Пароль: $NEW_USER_PASSWORD"
    echo "   • Аутентификация: Только SSH ключ"
    echo "   • Root SSH: ❌ Запрещен"
    echo "   • Парольная аутентификация: ❌ Отключена"
    echo ""
    echo "📂 ДИРЕКТОРИИ И ФАЙЛЫ:"
    echo "   • RemnaNode: /opt/remnanode/"
    echo "   • Zapret RUU GOV: /opt/remnanode/xray/share/zapret.dat"
    echo "   • SSL ключи: /etc/letsencrypt/live/$DOMAIN/"
    echo "   • Конфиг Nginx: /opt/nginx/nginx.conf"
    echo "   • Логи Nginx: /var/log/nginx/ (VOLUME NOT MOUNTED!)"
    echo "   • Логи RemnaNode: docker logs remnanode"
    echo "   • Логи Xray: docker exec remnanode tail -f /var/log/supervisor/xray.out.log"
    echo ""
    echo "🔍 ПРОВЕРКА ДОСТУПНОСТИ:"

    if docker ps | grep -q remnanode; then
        echo "   • RemnaNode контейнер: 🟢 Запущен"
    else
        echo "   • RemnaNode контейнер: 🔴 Остановлен"
    fi

    if docker ps | grep -q nginx; then
        echo "   • Nginx: 🟢 Запущен"
    else
        echo "   • Nginx: 🔴 Не запущен"
    fi

    echo ""
    echo "================================================"
    echo "🎉 Настройка CentOS 9 завершена успешно!"
    echo "================================================"
}

# Основная функция
main() {
    log "Начало настройки CentOS 9"
    
    load_env
    update_packages
    install_software
    create_user
    configure_ssh
    configure_fail2ban
    configure_ufw
    configure_docker
    get_ssl_certificates
    configure_nginx
    setup_cert_renewal
    setup_auto_reboot
    setup_remnanode

    print_post_setup_info
}

# Запуск основной функции
main "$@"

