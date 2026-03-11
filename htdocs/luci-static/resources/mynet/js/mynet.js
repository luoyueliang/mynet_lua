/**
 * mynet.js — MyNet LuCI 前端脚本
 * 处理 VPN 控制按钮、状态轮询、Toast 通知等交互。
 */

/* ─── 基础 Fetch 封装 ─────────────────────────────────────── */

/**
 * mnFetch — 向 LuCI AJAX 端点发送请求
 * @param {string}   url      - 完整 URL
 * @param {string}   method   - GET | POST
 * @param {object}   params   - 请求参数（POST: body；GET: 追加到 URL）
 * @param {function} onOk     - 成功回调 (data)
 * @param {function} onErr    - 失败回调 (errorMessage)
 */
function mnFetch(url, method, params, onOk, onErr) {
    var opts = { method: method, headers: {} };

    if (method === 'POST') {
        opts.headers['Content-Type'] = 'application/x-www-form-urlencoded';
        if (params) {
            opts.body = Object.keys(params)
                .map(function(k) {
                    return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
                }).join('&');
        }
    } else if (params) {
        var qs = Object.keys(params)
            .map(function(k) {
                return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
            }).join('&');
        url += (url.indexOf('?') >= 0 ? '&' : '?') + qs;
    }

    fetch(url, opts)
        .then(function(res) { return res.json(); })
        .then(function(data) {
            if (onOk) onOk(data);
        })
        .catch(function(err) {
            if (onErr) onErr(err.message || String(err));
        });
}

/* ─── Toast 通知 ─────────────────────────────────────────── */

var _toastTimer = null;

/**
 * mnShowToast — 显示底部弹窗通知
 * @param {string} msg   - 消息内容
 * @param {string} type  - '' (默认) 或 'error'
 */
function mnShowToast(msg, type) {
    var el = document.getElementById('mn-toast');
    if (!el) return;

    el.textContent = msg;
    el.className   = 'mn-toast' + (type === 'error' ? ' mn-toast-error' : '');

    if (_toastTimer) clearTimeout(_toastTimer);
    _toastTimer = setTimeout(function() {
        el.classList.add('mn-hidden');
    }, 3500);
}

/* ─── VPN 控制 ───────────────────────────────────────────── */

/**
 * mnApi — 通用 VPN 操作（start / stop / restart）
 * @param {string} action  - 'vpn_start' | 'vpn_stop' | 'vpn_restart'
 * @param {object} params  - 附加参数（可 null）
 * @param {HTMLElement} btn - 触发按钮（用于禁用/恢复）
 */
function mnApi(action, params, btn) {
    if (btn) btn.disabled = true;

    var baseUrl = window.location.pathname
        .replace(/\/admin\/mynet.*$/, '/admin/mynet/api/');
    var url = baseUrl + action;

    mnFetch(url, 'POST', params || {},
        function(data) {
            if (btn) btn.disabled = false;
            if (data.success) {
                mnShowToast(data.message || 'OK');
                setTimeout(mnRefreshStatus, 1500);
            } else {
                mnShowToast((data.message || 'Error'), 'error');
            }
        },
        function(err) {
            if (btn) btn.disabled = false;
            mnShowToast(err, 'error');
        }
    );
}

/* ─── 状态轮询 ───────────────────────────────────────────── */

/**
 * mnRefreshStatus — 拉取 VPN 服务状态并更新控制台指示点
 */
function mnRefreshStatus() {
    var baseUrl = window.location.pathname
        .replace(/\/admin\/mynet.*$/, '/admin/mynet/api/status');

    mnFetch(baseUrl, 'GET', null,
        function(data) {
            if (!data.success) return;
            _updateStatusDots(data.vpn_status === 'running');
        },
        null  // 静默失败
    );
}

function _updateStatusDots(running) {
    var dots = document.querySelectorAll('.mn-dot');
    dots.forEach(function(dot) {
        if (dot.closest('.mn-card-header')) {
            dot.className = 'mn-dot ' + (running ? 'mn-dot-green' : 'mn-dot-red');
        }
    });

    var labels = document.querySelectorAll('.mn-status-label strong, .mn-running, .mn-stopped');
    labels.forEach(function(el) {
        if (running) {
            el.className = 'mn-running';
        } else {
            el.className = 'mn-stopped';
        }
    });
}
