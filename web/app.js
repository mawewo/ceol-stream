/*
 * Ceòl Stream - Web UI Frontend
 * Single-page application for managing the audio streamer.
 */

(function () {
    "use strict";

    // --- API helpers ---

    async function api(method, path, body) {
        const opts = { method, headers: {} };
        if (body) {
            opts.headers["Content-Type"] = "application/json";
            opts.body = JSON.stringify(body);
        }
        const res = await fetch(path, opts);
        return res.json();
    }

    const get = (path) => api("GET", path);
    const post = (path, body) => api("POST", path, body);

    // --- Tab navigation ---

    document.querySelectorAll(".nav-btn").forEach((btn) => {
        btn.addEventListener("click", () => {
            document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
            document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
            btn.classList.add("active");
            document.getElementById("tab-" + btn.dataset.tab).classList.add("active");

            // Load data when switching tabs
            const tab = btn.dataset.tab;
            if (tab === "services") loadServices();
            else if (tab === "audio") loadDACs();
            else if (tab === "network") loadNetwork();
            else if (tab === "system") loadSystem();
        });
    });

    // --- Services ---

    async function loadServices() {
        const data = await get("/api/services");
        const container = document.getElementById("services-list");
        container.innerHTML = "";

        for (const [id, svc] of Object.entries(data.services)) {
            const card = document.createElement("div");
            card.className = "card";
            const dotClass = !svc.installed ? "not-installed" : svc.active ? "active" : "inactive";
            const stateText = !svc.installed ? "not installed" : svc.active ? "running" : "stopped";

            card.innerHTML = `
                <div class="service-card">
                    <div class="service-info">
                        <h3>
                            <span class="status-dot ${dotClass}"></span>
                            ${svc.name}
                        </h3>
                        <span class="service-state">${stateText}</span>
                        <p class="hint">${svc.description}</p>
                    </div>
                    <div class="service-actions">
                        ${svc.installed ? `
                            <label class="toggle" title="${svc.enabled ? 'Disable' : 'Enable'} service">
                                <input type="checkbox" ${svc.enabled ? "checked" : ""}
                                       data-service="${id}" data-action="toggle">
                                <span class="toggle-slider"></span>
                            </label>
                            <button class="btn btn-sm btn-ghost" data-service="${id}" data-action="restart"
                                    ${!svc.active ? 'disabled' : ''}>Restart</button>
                        ` : `<span class="hint">Install via setup script</span>`}
                    </div>
                </div>
            `;
            container.appendChild(card);
        }

        // Bind toggle events
        container.querySelectorAll("[data-action='toggle']").forEach((el) => {
            el.addEventListener("change", async (e) => {
                const svcId = e.target.dataset.service;
                const action = e.target.checked ? "enable" : "disable";
                e.target.disabled = true;
                await post("/api/services", { service: svcId, action });
                setTimeout(loadServices, 500);
            });
        });

        container.querySelectorAll("[data-action='restart']").forEach((el) => {
            el.addEventListener("click", async (e) => {
                const svcId = e.target.dataset.service;
                e.target.disabled = true;
                e.target.textContent = "...";
                await post("/api/services", { service: svcId, action: "restart" });
                setTimeout(loadServices, 1000);
            });
        });
    }

    // --- DACs ---

    async function loadDACs() {
        const data = await get("/api/dacs");
        const container = document.getElementById("dac-list");
        container.innerHTML = "";

        if (data.dacs.length === 0) {
            container.innerHTML = `
                <div class="card">
                    <p class="hint">No USB DAC detected. Connect a USB audio device and refresh.</p>
                    <button class="btn btn-sm" style="margin-top: 0.75rem;" onclick="loadDACs()">Refresh</button>
                </div>
            `;
            return;
        }

        for (const dac of data.dacs) {
            const card = document.createElement("div");
            const isSelected = data.selected === dac.alsa_device;
            card.className = "card dac-card" + (isSelected ? " selected" : "");

            const capsHtml = dac.max_bit_depth || dac.max_sample_rate || dac.dsd
                ? `<div class="dac-caps">
                    ${dac.max_bit_depth ? `<span class="dac-cap">${dac.max_bit_depth}-bit</span>` : ""}
                    ${dac.max_sample_rate ? `<span class="dac-cap">${dac.max_sample_rate_display}</span>` : ""}
                    ${dac.dsd ? `<span class="dac-cap dac-cap-dsd">DSD</span>` : `<span class="dac-cap dac-cap-no-dsd">No DSD</span>`}
                   </div>`
                : `<div class="dac-caps"><span class="dac-cap">Capabilities unknown</span></div>`;

            card.innerHTML = `
                <div class="dac-radio"></div>
                <div class="dac-info">
                    <h3>${dac.name}</h3>
                    <span class="device-id">${dac.alsa_device} — ${dac.device_name}</span>
                    ${capsHtml}
                </div>
            `;
            card.addEventListener("click", async () => {
                await post("/api/dacs", { dac: dac.alsa_device });
                document.getElementById("signal-dac-name").textContent = dac.name;
                loadDACs();
            });
            container.appendChild(card);
        }

        // Update signal path display
        if (data.selected) {
            const sel = data.dacs.find((d) => d.alsa_device === data.selected);
            if (sel) {
                document.getElementById("signal-dac-name").textContent = sel.name;
            }
        }
    }

    // --- Network ---

    async function loadNetwork() {
        const data = await get("/api/network");

        document.getElementById("hostname-input").value = data.hostname;
        document.getElementById("hostname-display").textContent = data.hostname;

        // WiFi status
        const wifiStatus = document.getElementById("wifi-status");
        const wifiDisconnectBtn = document.getElementById("wifi-disconnect-btn");
        if (data.wifi_connected) {
            wifiStatus.textContent = "Connected to " + data.wifi_connected;
            wifiStatus.className = "wifi-status connected";
            wifiDisconnectBtn.style.display = "inline-block";
        } else {
            wifiStatus.textContent = "Not connected";
            wifiStatus.className = "wifi-status";
            wifiDisconnectBtn.style.display = "none";
        }

        // Interfaces
        const container = document.getElementById("network-interfaces");
        container.innerHTML = "";
        for (const iface of data.interfaces) {
            const card = document.createElement("div");
            card.className = "card";
            card.innerHTML = `
                <div class="iface-card">
                    <div class="iface-info">
                        <h3>${iface.name}<span class="iface-type">${iface.type}</span></h3>
                        <span class="iface-addr">${iface.addresses.join(", ") || "No address"}</span>
                        <span class="service-state">${iface.state}</span>
                    </div>
                    <div class="service-actions">
                        <button class="btn btn-sm btn-ghost" data-iface="${iface.name}" data-action="dhcp">DHCP</button>
                        <button class="btn btn-sm btn-ghost" data-iface="${iface.name}" data-action="static">Static IP</button>
                    </div>
                </div>
            `;
            container.appendChild(card);
        }

        // Bind interface actions
        container.querySelectorAll("[data-action='dhcp']").forEach((el) => {
            el.addEventListener("click", async (e) => {
                const iface = e.target.dataset.iface;
                el.disabled = true;
                el.textContent = "...";
                await post("/api/network/dhcp", { interface: iface });
                setTimeout(loadNetwork, 2000);
            });
        });

        container.querySelectorAll("[data-action='static']").forEach((el) => {
            el.addEventListener("click", (e) => {
                const iface = e.target.dataset.iface;
                showStaticDialog(iface);
            });
        });
    }

    // Hostname save
    document.getElementById("hostname-save").addEventListener("click", async () => {
        const btn = document.getElementById("hostname-save");
        const name = document.getElementById("hostname-input").value.trim();
        btn.disabled = true;
        btn.textContent = "...";
        const data = await post("/api/hostname", { hostname: name });
        if (data.error) {
            alert(data.error);
        } else {
            document.getElementById("hostname-display").textContent = name;
        }
        btn.disabled = false;
        btn.textContent = "Save";
    });

    // WiFi scan
    document.getElementById("wifi-scan-btn").addEventListener("click", async () => {
        const btn = document.getElementById("wifi-scan-btn");
        const container = document.getElementById("wifi-networks");
        btn.disabled = true;
        btn.textContent = "Scanning...";
        container.style.display = "block";
        container.innerHTML = '<div class="hint">Scanning...</div>';

        const data = await get("/api/wifi/scan");
        container.innerHTML = "";
        for (const net of data.networks) {
            const item = document.createElement("div");
            item.className = "wifi-item";
            item.innerHTML = `
                <span>${net.ssid}</span>
                <span>
                    <span class="wifi-signal">${net.signal}%</span>
                    <span class="wifi-security">${net.security}</span>
                </span>
            `;
            item.addEventListener("click", () => showWifiDialog(net.ssid, net.security));
            container.appendChild(item);
        }
        if (data.networks.length === 0) {
            container.innerHTML = '<div class="hint">No networks found.</div>';
        }
        btn.disabled = false;
        btn.textContent = "Scan Networks";
    });

    // WiFi disconnect
    document.getElementById("wifi-disconnect-btn").addEventListener("click", async () => {
        const btn = document.getElementById("wifi-disconnect-btn");
        btn.disabled = true;
        btn.textContent = "Disconnecting...";
        const data = await post("/api/wifi/disconnect");
        if (data.error) {
            alert(data.error);
        }
        btn.disabled = false;
        btn.textContent = "Disconnect";
        setTimeout(loadNetwork, 2000);
    });

    // WiFi connect dialog
    function showWifiDialog(ssid, security) {
        document.getElementById("wifi-dialog").style.display = "flex";
        document.getElementById("wifi-dialog-ssid").textContent = ssid;
        document.getElementById("wifi-password").value = "";
        if (security === "Open") {
            // Connect directly without password
            connectWifi(ssid, "");
            return;
        }
        document.getElementById("wifi-password").focus();

        document.getElementById("wifi-connect").onclick = () => {
            const pw = document.getElementById("wifi-password").value;
            connectWifi(ssid, pw);
        };
    }

    async function connectWifi(ssid, password) {
        document.getElementById("wifi-dialog").style.display = "none";
        const data = await post("/api/wifi/connect", { ssid, password });
        if (data.error) {
            alert(data.error);
        }
        setTimeout(loadNetwork, 2000);
    }

    document.getElementById("wifi-cancel").addEventListener("click", () => {
        document.getElementById("wifi-dialog").style.display = "none";
    });

    // Static IP dialog
    function showStaticDialog(iface) {
        document.getElementById("static-dialog").style.display = "flex";
        document.getElementById("static-dialog-iface").textContent = iface;
        document.getElementById("static-ip").value = "";
        document.getElementById("static-gateway").value = "";
        document.getElementById("static-dns").value = "";
        document.getElementById("static-ip").focus();

        document.getElementById("static-save").onclick = async () => {
            const ip = document.getElementById("static-ip").value.trim();
            const gateway = document.getElementById("static-gateway").value.trim();
            const dns = document.getElementById("static-dns").value.trim();
            document.getElementById("static-dialog").style.display = "none";
            const data = await post("/api/network/static", { interface: iface, ip, gateway, dns });
            if (data.error) alert(data.error);
            setTimeout(loadNetwork, 2000);
        };
    }

    document.getElementById("static-cancel").addEventListener("click", () => {
        document.getElementById("static-dialog").style.display = "none";
    });

    // Close dialogs on overlay click
    document.querySelectorAll(".dialog-overlay").forEach((el) => {
        el.addEventListener("click", (e) => {
            if (e.target === el) el.style.display = "none";
        });
    });

    // --- System ---

    async function loadSystem() {
        const data = await get("/api/system");
        const container = document.getElementById("system-info");
        container.innerHTML = `
            <div class="sys-grid">
                <div class="sys-item"><span class="sys-label">Hostname</span><span class="sys-value">${data.hostname}</span></div>
                <div class="sys-item"><span class="sys-label">Uptime</span><span class="sys-value">${data.uptime}</span></div>
                <div class="sys-item"><span class="sys-label">Architecture</span><span class="sys-value">${data.arch}</span></div>
                <div class="sys-item"><span class="sys-label">Kernel</span><span class="sys-value">${data.kernel}</span></div>
                <div class="sys-item"><span class="sys-label">Distribution</span><span class="sys-value">${data.distro}</span></div>
                <div class="sys-item"><span class="sys-label">Memory</span><span class="sys-value">${data.memory}</span></div>
                ${data.cpu_temp ? `<div class="sys-item"><span class="sys-label">CPU Temp</span><span class="sys-value">${data.cpu_temp} C</span></div>` : ""}
            </div>
        `;
    }

    // System update with live progress
    let updatePollTimer = null;

    async function pollUpdateStatus() {
        const btn = document.getElementById("update-btn");
        const output = document.getElementById("update-output");
        try {
            const data = await get("/api/system/update");
            output.textContent = data.output || "";
            // Auto-scroll to bottom
            output.scrollTop = output.scrollHeight;

            if (data.running) {
                updatePollTimer = setTimeout(pollUpdateStatus, 1500);
            } else {
                // Update finished
                updatePollTimer = null;
                btn.disabled = false;
                if (data.rc === 0) {
                    btn.textContent = "Update Complete";
                    btn.classList.add("btn-success");
                } else if (data.rc !== null) {
                    btn.textContent = "Update Failed";
                    btn.classList.add("btn-danger");
                } else {
                    btn.textContent = "Update System";
                }
                // Reset button text after a few seconds
                setTimeout(() => {
                    btn.textContent = "Update System";
                    btn.classList.remove("btn-success", "btn-danger");
                }, 5000);
            }
        } catch {
            updatePollTimer = null;
            btn.disabled = false;
            btn.textContent = "Update System";
        }
    }

    document.getElementById("update-btn").addEventListener("click", async () => {
        const btn = document.getElementById("update-btn");
        const output = document.getElementById("update-output");
        if (!confirm("Run system update? Services will continue running.")) return;
        btn.disabled = true;
        btn.textContent = "Updating...";
        output.style.display = "block";
        output.textContent = "Starting system update...\n";

        const data = await post("/api/system/update");
        if (data.error) {
            output.textContent = data.error;
            btn.disabled = false;
            btn.textContent = "Update System";
            return;
        }
        // Start polling for progress
        updatePollTimer = setTimeout(pollUpdateStatus, 1000);
    });

    // Reboot
    document.getElementById("reboot-btn").addEventListener("click", async () => {
        if (!confirm("Reboot the system? All services will restart automatically.")) return;
        await post("/api/system/reboot");
        document.body.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100vh;color:#7a7a8a;">Rebooting... Refresh this page in a moment.</div>';
    });

    // --- Initial load ---
    loadServices();
})();
