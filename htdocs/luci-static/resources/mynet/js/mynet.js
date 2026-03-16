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
                .map(function (k) {
                    return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
                }).join('&');
        }
    } else if (params) {
        var qs = Object.keys(params)
            .map(function (k) {
                return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
            }).join('&');
        url += (url.indexOf('?') >= 0 ? '&' : '?') + qs;
    }

    fetch(url, opts)
        .then(function (res) { return res.json(); })
        .then(function (data) {
            if (onOk) onOk(data);
        })
        .catch(function (err) {
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
    el.className = 'mn-toast' + (type === 'error' ? ' mn-toast-error' : '');

    if (_toastTimer) clearTimeout(_toastTimer);
    _toastTimer = setTimeout(function () {
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

    var url = _mnApiBase() + action;

    mnFetch(url, 'POST', params || {},
        function (data) {
            if (btn) btn.disabled = false;
            if (data.success) {
                mnShowToast(data.message || 'OK');
                setTimeout(mnRefreshStatus, 1500);
            } else {
                mnShowToast((data.message || 'Error'), 'error');
            }
        },
        function (err) {
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
    mnFetch(_mnApiBase() + 'status', 'GET', null,
        function (data) {
            if (!data.success) return;
            _updateStatusDots(data.vpn_status === 'running');
        },
        null  // 静默失败
    );
}

function _updateStatusDots(running) {
    var dots = document.querySelectorAll('.mn-dot');
    dots.forEach(function (dot) {
        if (dot.closest('.mn-card-header')) {
            dot.className = 'mn-dot ' + (running ? 'mn-dot-green' : 'mn-dot-red');
        }
    });

    // node 页专用状态点 + 标签
    var nodeDot = document.getElementById('mn-vpn-dot');
    if (nodeDot) nodeDot.className = 'mn-dot ' + (running ? 'mn-dot-green' : 'mn-dot-red');

    var nodeLabel = document.getElementById('mn-vpn-label');
    if (nodeLabel) {
        nodeLabel.textContent = running ? 'Running' : 'Stopped';
        nodeLabel.className   = running ? 'mn-dep-ok' : 'mn-dep-fail';
    }

    var labels = document.querySelectorAll('.mn-status-label strong, .mn-running, .mn-stopped');
    labels.forEach(function (el) {
        if (running) {
            el.className = 'mn-running';
        } else {
            el.className = 'mn-stopped';
        }
    });
}

/* ─── GNB 自动安装 ───────────────────────────────────────── */

var _gnbInstallTimer = null;

/**
 * mnAutoInstallGnb — 页面加载时调用。
 * 若服务端渲染的 window.mnGnbCtlOk === false，自动触发后台安装（防重入由服务端控制）。
 * 参考 mynet_tui startup_helper.go autoInstallDrivers()
 */
function mnAutoInstallGnb() {
    if (window.mnGnbCtlOk) return;   // gnb_ctl 已存在，无需操作

    var panel = document.getElementById('mn-gnb-install-panel');
    if (!panel) return;

    panel.classList.remove('mn-hidden');
    _gnbSetMsg('正在触发 GNB 自动安装…', false);

    var baseUrl = _mnApiBase();

    // 调用 api_gnb_auto_install（防重入：服务端保证只启动一次）
    mnFetch(baseUrl + 'gnb_auto_install', 'POST', {},
        function (data) {
            if (data.status === 'already_ok') {
                _gnbSetMsg('gnb_ctl 已安装 ✓', false);
                _gnbMarkDepOk('gnb_ctl');
                setTimeout(function () { panel.classList.add('mn-hidden'); }, 3000);
                return;
            }
            if (data.status === 'error') {
                _gnbSetMsg('自动安装失败: ' + (data.message || ''), true);
                return;
            }
            // started 或 already_running → 开始轮询
            var archHint = data.arch ? (' (' + (data.os_name || '') + '/' + data.arch + ')') : '';
            _gnbSetMsg('正在安装 GNB' + archHint + '…', false);
            _gnbPollStatus();
        },
        function (err) {
            _gnbSetMsg('请求失败: ' + err, true);
        }
    );
}

/** _gnbPollStatus — 每 3 秒轮询 api_gnb_install_status，直到完成或失败 */
function _gnbPollStatus() {
    if (_gnbInstallTimer) return;   // 已在轮询
    _gnbInstallTimer = setInterval(function () {
        var baseUrl = _mnApiBase();
        mnFetch(baseUrl + 'gnb_install_status', 'GET', null,
            function (resp) {
                if (!resp.success || !resp.data) return;
                var d = resp.data;

                // 显示最新日志（最后 3 行）
                if (d.log_tail && d.log_tail !== '') {
                    var lines = d.log_tail.split('\n').filter(function (l) { return l.trim(); });
                    var last3 = lines.slice(-3).join('\n');
                    var logEl = document.getElementById('mn-gnb-install-log');
                    if (logEl) {
                        logEl.textContent = last3;
                        logEl.classList.remove('mn-hidden');
                    }
                }

                if (d.gnb_exists) {
                    // 安装成功
                    clearInterval(_gnbInstallTimer); _gnbInstallTimer = null;
                    _gnbSetMsg('GNB 安装完成 ✓', false);
                    _gnbMarkDepOk('gnb_ctl');
                    window.mnGnbCtlOk = true;
                    setTimeout(function () {
                        var panel = document.getElementById('mn-gnb-install-panel');
                        if (panel) panel.classList.add('mn-hidden');
                    }, 5000);
                    return;
                }

                if (d.done && d.failed) {
                    clearInterval(_gnbInstallTimer); _gnbInstallTimer = null;
                    _gnbSetMsg('安装失败，查看日志', true);
                    return;
                }

                if (!d.running && d.done) {
                    // 安装脚本退出但未检测到 gnb_exists（可能延迟）
                    clearInterval(_gnbInstallTimer); _gnbInstallTimer = null;
                    _gnbSetMsg('安装脚本已完成，刷新页面检查', false);
                    return;
                }
            },
            null  // 静默失败
        );
    }, 3000);
}

/** _gnbSetMsg — 更新进度消息和图标状态；isError=true 时显示重试按钮 */
function _gnbSetMsg(msg, isError) {
    var msgEl    = document.getElementById('mn-gnb-install-msg');
    var iconEl   = document.getElementById('mn-gnb-install-icon');
    var retryBtn = document.getElementById('mn-gnb-retry-btn');
    if (msgEl)  msgEl.textContent = msg;
    if (iconEl) {
        if (isError) {
            iconEl.textContent = '✗';
            iconEl.className = 'mn-dep-fail';
        } else if (msg.indexOf('✓') >= 0) {
            iconEl.textContent = '✓';
            iconEl.className = 'mn-dep-ok';
        } else {
            iconEl.textContent = '⟳';
            iconEl.className = 'mn-gnb-spin';
        }
    }
    // 失败时显示重试按钮，进行中或成功时隐藏
    if (retryBtn) retryBtn.classList.toggle('mn-hidden', !isError);
}

/** mnRetryInstallGnb — 手动重试安装（强刷入口） */
function mnRetryInstallGnb() {
    if (_gnbInstallTimer) { clearInterval(_gnbInstallTimer); _gnbInstallTimer = null; }
    window.mnGnbCtlOk = false;
    var logEl = document.getElementById('mn-gnb-install-log');
    if (logEl) { logEl.textContent = ''; logEl.classList.add('mn-hidden'); }
    mnAutoInstallGnb();
}

/** _gnbMarkDepOk — 将依赖列表中 gnb_ctl 标记为绿色 ✓ */
function _gnbMarkDepOk(depName) {
    var items = document.querySelectorAll('[data-dep="' + depName + '"]');
    items.forEach(function (el) {
        el.className = 'mn-dep-item mn-dep-ok';
        el.textContent = depName + ' ✓';
    });
}

/** _mnApiBase — 构造 API 基础 URL */
function _mnApiBase() {
    return window.location.pathname
        .replace(/\/admin\/services\/mynet.*$/, '/admin/services/mynet/api/');
}

/** mnToggle — 切换元素可见性，并更新按钮图标和文字
 *  @param {string}      elId  要切换的元素 ID
 *  @param {HTMLElement} btn   触发按钮（可选，更新其内容）
 */
function mnToggle(elId, btn) {
    var el = document.getElementById(elId);
    if (!el) return;
    var hidden = el.classList.contains('mn-hidden');
    if (hidden) {
        el.classList.remove('mn-hidden');
        if (btn) btn.innerHTML = btn.dataset.labelCollapse || '&#9650; Hide';
    } else {
        el.classList.add('mn-hidden');
        if (btn) btn.innerHTML = btn.dataset.labelExpand  || '&#9660; View';
    }
}

// ─────────────────────────────────────────────────────────────
// Node 配置页 JS
// ─────────────────────────────────────────────────────────────

/** mnNodeRefreshConfig — 刷新单个配置文件
 *  @param {string} cfgType  "node" | "route" | "address"
 *  @param {HTMLElement} btn  按钮元素（显示加载状态）
 */
function mnNodeRefreshConfig(cfgType, btn) {
    var nodeId = window.mnCurrentNodeId;
    if (!nodeId) { return; }
    var orig = btn ? btn.textContent : '';
    if (btn) { btn.disabled = true; btn.textContent = '…'; }

    var statusEl = document.getElementById('mn-cfg-' + cfgType + '-status');
    if (statusEl) { statusEl.textContent = ''; statusEl.className = 'mn-config-status mn-muted mn-small'; }

    mnFetch(_mnApiBase() + 'node_config', 'POST',
        { node_id: nodeId, type: cfgType },
        function (data) {
            if (btn) { btn.disabled = false; btn.textContent = orig; }
            if (statusEl) {
                if (data.success) {
                    statusEl.textContent = '✓ updated';
                    statusEl.className = 'mn-config-status mn-dep-ok mn-small';
                } else {
                    statusEl.textContent = '✗ ' + (data.error || data.message || 'failed');
                    statusEl.className = 'mn-config-status mn-dep-fail mn-small';
                }
            }
            // 如果有配置内容返回则刷新 pre 块（当前实现是页面刷新）
            if (data.success) {
                setTimeout(function () { window.location.reload(); }, 800);
            }
        },
        function (err) {
            if (btn) { btn.disabled = false; btn.textContent = orig; }
            if (statusEl) {
                statusEl.textContent = '✗ ' + err;
                statusEl.className = 'mn-config-status mn-dep-fail mn-small';
            }
        }
    );
}

/** mnNodeRefreshAll — 一键刷新全部配置 */
function mnNodeRefreshAll() {
    var nodeId = window.mnCurrentNodeId;
    if (!nodeId) { return; }
    var gEl = document.getElementById('mn-node-global-status');
    if (gEl) { gEl.textContent = 'Refreshing…'; gEl.className = 'mn-small mn-muted'; }

    mnFetch(_mnApiBase() + 'node_config', 'POST',
        { node_id: nodeId, type: 'all' },
        function (data) {
            if (gEl) {
                if (data.success) {
                    gEl.textContent = '✓ All configs refreshed (' + (data.files ? data.files.length : 0) + ' files)';
                    gEl.className = 'mn-small mn-dep-ok';
                    setTimeout(function () { window.location.reload(); }, 800);
                } else {
                    var errs = data.errors && data.errors.length ? data.errors.join('; ') : (data.message || 'failed');
                    gEl.textContent = '✗ ' + errs;
                    gEl.className = 'mn-small mn-dep-fail';
                }
            }
        },
        function (err) {
            if (gEl) { gEl.textContent = '✗ ' + err; gEl.className = 'mn-small mn-dep-fail'; }
        }
    );
}

/** mnNodeSwitch — 切换节点 */
function mnNodeSwitch() {
    var sel = document.getElementById('mn-switch-node-id');
    if (!sel) return;
    var nodeId = sel.value;
    if (!nodeId) return;

    var selOpt  = sel.options[sel.selectedIndex];
    var label   = selOpt ? selOpt.text.trim() : nodeId;
    if (!window.confirm('Switch to node:\n' + label + '\n\nThis will save the new node configuration. Continue?')) return;

    var resEl = document.getElementById('mn-switch-result');
    if (resEl) { resEl.textContent = 'Switching…'; resEl.className = 'mn-small mn-muted'; resEl.style.display = 'block'; }

    mnFetch(_mnApiBase() + 'node_switch', 'POST',
        { node_id: nodeId },
        function (data) {
            if (data.success) {
                if (resEl) { resEl.textContent = '✓ ' + (data.message || 'switched'); resEl.className = 'mn-small mn-dep-ok'; }
                setTimeout(function () {
                    window.location.href = data.redirect || window.location.pathname;
                }, 600);
            } else {
                if (resEl) { resEl.textContent = '✗ ' + (data.message || 'switch failed'); resEl.className = 'mn-small mn-dep-fail'; }
            }
        },
        function (err) {
            if (resEl) { resEl.textContent = '✗ ' + err; resEl.className = 'mn-small mn-dep-fail'; }
        }
    );
}

/** mnKeyMode — 切换私钥操作模式（file / paste / gen），三选一互斥 */
function mnKeyMode(mode) {
    var modes = ['file', 'paste', 'gen'];
    modes.forEach(function(m) {
        var panel = document.getElementById('mn-keymode-' + m);
        var btn   = document.getElementById('mn-keymode-' + m + '-btn');
        if (panel) panel.classList.toggle('mn-hidden', m !== mode);
        if (btn) {
            btn.classList.toggle('mn-btn-active', m === mode);
            btn.classList.toggle('mn-btn-secondary', m !== mode);
        }
    });
}

/** mnNodeSavePrivKey — 保存私钥（从文件或输入框） */
function mnNodeSavePrivKey(mode) {
    var nodeId   = window.mnCurrentNodeId;
    // 兼容旧调用（无参数时）和新模式参数
    if (!mode) mode = 'file';
    var statusId = (mode === 'paste') ? 'mn-privkey-paste-status' : 'mn-privkey-status';
    var statusEl = document.getElementById(statusId);
    if (!nodeId) return;

    function _doSave(hexStr) {
        hexStr = hexStr.replace(/\s+/g, '');
        if (!hexStr) {
            if (statusEl) { statusEl.textContent = 'Key is empty'; statusEl.className = 'mn-small mn-dep-fail'; }
            return;
        }
        if (hexStr.length !== 128 || !/^[0-9a-fA-F]{128}$/.test(hexStr)) {
            if (statusEl) { statusEl.textContent = '\u2717 Must be 128 hex characters (got ' + hexStr.length + ')'; statusEl.className = 'mn-small mn-dep-fail'; }
            return;
        }
        if (statusEl) { statusEl.textContent = 'Saving…'; statusEl.className = 'mn-small mn-muted'; }

        mnFetch(_mnApiBase() + 'node_save_key', 'POST',
            { node_id: nodeId, key_hex: hexStr },
            function (data) {
                if (statusEl) {
                    if (data.success) {
                        statusEl.textContent = '✓ Saved';
                        statusEl.className = 'mn-small mn-dep-ok';
                        setTimeout(function () { window.location.reload(); }, 800);
                    } else {
                        statusEl.textContent = '✗ ' + (data.message || 'save failed');
                        statusEl.className = 'mn-small mn-dep-fail';
                    }
                }
            },
            function (err) {
                if (statusEl) { statusEl.textContent = '✗ ' + err; statusEl.className = 'mn-small mn-dep-fail'; }
            }
        );
    }

    if (mode === 'file') {
        var fileInput = document.getElementById('mn-privkey-file');
        if (fileInput && fileInput.files && fileInput.files[0]) {
            var reader = new FileReader();
            reader.onload = function (e) { _doSave(e.target.result || ''); };
            reader.readAsText(fileInput.files[0]);
            return;
        }
        if (statusEl) { statusEl.textContent = 'No file selected'; statusEl.className = 'mn-small mn-dep-fail'; }
        return;
    }

    if (mode === 'paste') {
        var textInput = document.getElementById('mn-privkey-input');
        if (textInput && textInput.value.trim() !== '') {
            _doSave(textInput.value);
            return;
        }
        if (statusEl) { statusEl.textContent = 'No key pasted'; statusEl.className = 'mn-small mn-dep-fail'; }
        return;
    }

    if (statusEl) { statusEl.textContent = 'No key provided'; statusEl.className = 'mn-small mn-dep-fail'; }
}

/**
 * mnNodeGenKey — 在服务器上生成新 GNB 密钥对并上传公钥
 * 生成流程：调用 gnb_crypto 生成密钥对 → 私钥保存本地 → 公钥上传服务器
 * 操作前需用户确认（此操作会导致所有对端节点需要重新交换公钥）
 */
function mnNodeGenKey() {
    var nodeId   = window.mnCurrentNodeId;
    var statusEl = document.getElementById('mn-genkey-status');
    if (!nodeId || nodeId === '0' || nodeId === '') {
        if (statusEl) { statusEl.textContent = 'No node selected'; statusEl.className = 'mn-small mn-dep-fail'; }
        return;
    }

    var confirmed = window.confirm(
        '⚠ Warning: Generating a new key pair will replace the current private key.\n\n' +
        'After generation, ALL peer nodes will need to re-fetch and update their public key files ' +
        'before the VPN can reconnect.\n\n' +
        'Continue?'
    );
    if (!confirmed) return;

    if (statusEl) { statusEl.textContent = 'Generating key pair…'; statusEl.className = 'mn-small mn-muted'; }

    mnFetch(_mnApiBase() + 'node_gen_key', 'POST',
        { node_id: nodeId },
        function (data) {
            if (data.success) {
                if (statusEl) {
                    statusEl.textContent = '✓ New key pair generated and public key uploaded. pub: ' +
                        (data.pub_hex ? data.pub_hex.substring(0, 16) + '…' : '');
                    statusEl.className = 'mn-small mn-dep-ok';
                }
                setTimeout(function () { window.location.reload(); }, 1200);
            } else {
                if (statusEl) {
                    statusEl.textContent = '✗ ' + (data.message || 'generation failed');
                    statusEl.className = 'mn-small mn-dep-fail';
                }
            }
        },
        function (err) {
            if (statusEl) { statusEl.textContent = '✗ ' + err; statusEl.className = 'mn-small mn-dep-fail'; }
        }
    );
}

/** mnInstallSystemDeps — 安装系统依赖（kmod-tun / bash / curl-tls） */
function mnInstallSystemDeps(btn) {
    var statusEl = document.getElementById('mn-sysdesp-status');
    if (btn) { btn.disabled = true; btn.textContent = '…'; }
    if (statusEl) { statusEl.textContent = 'Installing…'; statusEl.className = 'mn-small mn-muted'; }

    mnFetch(_mnApiBase() + 'install_system_deps', 'POST', {},
        function (data) {
            if (btn) { btn.disabled = false; btn.textContent = '⚡ Auto-Install'; }
            if (data.success) {
                var errs = data.errors && data.errors.length;
                if (statusEl) {
                    statusEl.textContent = errs ? ('⚠ partial: ' + data.errors.join(', ')) : '✓ Done';
                    statusEl.className = 'mn-small ' + (errs ? 'mn-dep-fail' : 'mn-dep-ok');
                }
                setTimeout(function () { window.location.reload(); }, 1200);
            } else {
                if (statusEl) { statusEl.textContent = '✗ ' + (data.message || 'failed'); statusEl.className = 'mn-small mn-dep-fail'; }
            }
        },
        function (err) {
            if (btn) { btn.disabled = false; btn.textContent = '⚡ Auto-Install'; }
            if (statusEl) { statusEl.textContent = '✗ ' + err; statusEl.className = 'mn-small mn-dep-fail'; }
        }
    );
}
