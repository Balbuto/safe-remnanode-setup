#!/usr/bin/env bash
# --- Встроенные статические шаблоны без внешних ресурсов ---
# Фиксированный каталог: идентификатор темы не используется как имя файла или команда.
rn_render_page_template() (
    local template="${1:-status}" title subtitle label bg surface fg muted accent
    case "$template" in
        status)
            title='Технические работы'; subtitle='Мы обновляем сайт. Пожалуйста, зайдите немного позже.'
            label='Обслуживание'; bg='#eef3f8'; surface='#ffffff'; fg='#15263b'; muted='#43546b'; accent='#174da1'
            ;;
        minimal)
            title='Скоро вернёмся'; subtitle='Страница временно недоступна. Спасибо за терпение.'
            label='Уведомление'; bg='#f8f2e7'; surface='#fffdfa'; fg='#2f2118'; muted='#655346'; accent='#923416'
            ;;
        dark)
            title='Сайт временно недоступен'; subtitle='Сервис на паузе, пока мы проводим обслуживание.'
            label='Техническая пауза'; bg='#101722'; surface='#1a2636'; fg='#f1f6fd'; muted='#b5c3d5'; accent='#81e3ba'
            ;;
        *) return 1 ;;
    esac

    install -d -m 0755 "$RN_WWW_DIR" || return 1
    local tmp
    tmp=$(mktemp "$RN_WWW_DIR/.index.XXXXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    cat > "$tmp" <<EOF || return 1
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="$([[ "$template" == dark ]] && printf dark || printf light)">
<meta name="remnanode-template" content="$template">
<title>$title</title>
<style>
:root{background:$bg;color:$fg;font-family:system-ui,sans-serif}
*{box-sizing:border-box}
body{min-height:100vh;margin:0;display:grid;place-items:center;padding:1.5rem}
main{background:$surface;width:min(100%,39rem);padding:clamp(1.75rem,7vw,4rem);border-radius:1.25rem;border:1px solid $muted}
.tag{color:$accent;font-size:.8rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase}
h1{font-size:clamp(2rem,7vw,3.6rem);line-height:1.04;letter-spacing:-.04em;margin:1rem 0;overflow-wrap:anywhere}
p{font-size:1.05rem;line-height:1.6;color:$muted;margin-bottom:0}
</style>
</head>
<body><main>
<div class="tag">$label</div>
<h1>$title</h1>
<p>$subtitle</p>
</main></body>
</html>
EOF
    chmod 0644 "$tmp" && mv -fT -- "$tmp" "$RN_WWW_DIR/index.html"
)

rn_pick_page_template() {
    local selection
    local -a templates=(status minimal dark)
    printf '%s\n' 'Темы: 1 — статус, 2 — минимализм, 3 — тёмная, 4 — случайная, 0 — отмена.' >&2
    read -r -p 'Выберите тему [1]: ' selection || return 1
    case "${selection:-1}" in
        1) printf 'status\n' ;;
        2) printf 'minimal\n' ;;
        3) printf 'dark\n' ;;
        4) printf '%s\n' "${templates[RANDOM % ${#templates[@]}]}" ;;
        0) return 2 ;;
        *) printf '%s\n' 'Некорректный номер темы.' >&2; return 1 ;;
    esac
}
