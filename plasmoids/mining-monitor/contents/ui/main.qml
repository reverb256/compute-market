// Mining Monitor Plasmoid - Multi-node GPU/CPU mining dashboard
// Fetches metrics from Prometheus (node-exporter + mining-exporter + xmrig-metrics)
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

PlasmaExtras.ExpandableListItem {
    id: miningRoot

    // ── Configuration ──
    property string prometheusUrl: "http://127.0.0.1:9090"
    property int refreshInterval: 10000
    property string clusterNodes: "zephyr,nexus,forge,sentry"

    // ── State ──
    property var nodeData: ({})
    property var totalHashrate: 0
    property int activeNodes: 0

    icon: "view-statistics"
    title: "⛏ Mining Monitor"
    subtitle: activeNodes > 0
        ? `${activeNodes} nodes · ${formatHashrate(totalHashrate)}`
        : "Loading..."
    defaultExpanded: false

    // ── Prometheus Query Helper ──
    function instantQuery(query) {
        var doc = new XMLHttpRequest();
        var result = [];
        doc.open(
            "GET",
            `${prometheusUrl}/api/v1/query?query=${encodeURIComponent(query)}`,
            false
        );
        try { doc.send(); } catch(e) { return result; }
        if (doc.status === 200) {
            var resp = JSON.parse(doc.responseText);
            if (resp.status === "success" && resp.data && resp.data.result) {
                result = resp.data.result;
            }
        }
        return result;
    }

    function rangeQuery(query, duration) {
        duration = duration || "5m";
        var doc = new XMLHttpRequest();
        var result = [];
        var end = Math.floor(Date.now() / 1000);
        var start = end - 300;
        doc.open(
            "GET",
            `${prometheusUrl}/api/v1/query_range?query=${encodeURIComponent(query)}&start=${start}&end=${end}&step=60`,
            false
        );
        try { doc.send(); } catch(e) { return result; }
        if (doc.status === 200) {
            var resp = JSON.parse(doc.responseText);
            if (resp.status === "success" && resp.data && resp.data.result) {
                result = resp.data.result;
            }
        }
        return result;
    }

    // ── Formatters ──
    function formatHashrate(hs) {
        if (hs >= 1e12) return (hs / 1e12).toFixed(2) + " TH/s";
        if (hs >= 1e9)  return (hs / 1e9).toFixed(2) + " GH/s";
        if (hs >= 1e6)  return (hs / 1e6).toFixed(2) + " MH/s";
        if (hs >= 1e3)  return (hs / 1e3).toFixed(2) + " KH/s";
        return hs.toFixed(0) + " H/s";
    }

    function formatPower(w) {
        if (w >= 1000) return (w / 1000).toFixed(1) + " kW";
        return w.toFixed(0) + " W";
    }

    function formatTemp(t) {
        return t !== null ? t.toFixed(0) + "°C" : "N/A";
    }

    function nodeLabel(instance) {
        return instance.replace(/:.*$/, "");
    }

    function getGpuColor(name) {
        if (name.indexOf("3090") >= 0) return "#ff6b6b";
        if (name.indexOf("3060") >= 0) return "#4ecdc4";
        if (name.indexOf("4060") >= 0) return "#45b7d1";
        if (name.indexOf("5700") >= 0) return "#f9ca24";
        if (name.indexOf("5600") >= 0) return "#a29bfe";
        return "#dfe6e9";
    }

    // ── Data Fetching ──
    function fetchData() {
        var data = {};
        var totalHs = 0;
        var active = 0;
        var nodes = clusterNodes.split(",");

        for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i].trim();
            var nd = {
                name: node,
                xmrigHashrate: 0,
                xmrigWorkers: 0,
                gpus: []
            };

            // XMRig CPU mining hashrate (from xmrig-metrics textfile collector)
            var xmrigResults = instantQuery(
                `xmrig_hashrate{instance=~"${node}:.*"}`
            );
            for (var j = 0; j < xmrigResults.length; j++) {
                nd.xmrigHashrate += parseFloat(xmrigResults[j].value[1]) || 0;
                nd.xmrigWorkers++;
            }

            // GPU mining hashrate (from mining-exporter)
            var gpuHashResults = instantQuery(
                `mining_gpu_hashrate{instance=~"${node}:.*"}`
            );
            for (var j = 0; j < gpuHashResults.length; j++) {
                var gpu = gpuHashResults[j].metric || {};
                nd.gpus.push({
                    name: gpu.gpu_name || "GPU " + (j + 1),
                    hashrate: parseFloat(gpuHashResults[j].value[1]) || 0,
                    power: null,
                    temp: null,
                    fan: null,
                    color: getGpuColor(gpu.gpu_name || "")
                });
            }

            // GPU power draw
            var gpuPowerResults = instantQuery(
                `mining_gpu_power_watts{instance=~"${node}:.*"}`
            );
            for (var j = 0; j < gpuPowerResults.length; j++) {
                if (nd.gpus[j]) {
                    nd.gpus[j].power = parseFloat(gpuPowerResults[j].value[1]) || 0;
                }
            }

            // GPU temperature (from DCGM/nvidia-exporter)
            var gpuTempResults = instantQuery(
                `DCGM_FI_DEV_GPU_TEMP{instance=~"${node}:.*"}`
            );
            for (var j = 0; j < gpuTempResults.length; j++) {
                if (nd.gpus[j]) {
                    nd.gpus[j].temp = parseFloat(gpuTempResults[j].value[1]) || null;
                }
            }

            // Total node hashrate
            var nodeHs = nd.xmrigHashrate;
            for (var j = 0; j < nd.gpus.length; j++) {
                nodeHs += nd.gpus[j].hashrate;
            }

            nd.totalHashrate = nodeHs;
            if (nodeHs > 0) active++;
            totalHs += nodeHs;
            data[node] = nd;
        }

        nodeData = data;
        totalHashrate = totalHs;
        activeNodes = active;
    }

    // ── Timer ──
    Timer {
        interval: miningRoot.refreshInterval
        running: true
        repeat: true
        triggered: fetchData
    }

    // ── Content ──
    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        // ── Summary Bar ──
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: childrenRect.height + Kirigami.Units.smallSpacing * 2
            color: Qt.rgba(1, 1, 1, 0.05)
            radius: Kirigami.Units.smallSpacing

            RowLayout {
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    margins: Kirigami.Units.smallSpacing
                }
                spacing: Kirigami.Units.largeSpacing

                // Total hashrate
                Column {
                    Kirigami.Heading {
                        level: 5
                        text: "Combined"
                        color: Kirigami.Theme.disabledTextColor
                    }
                    PlasmaComponents.Label {
                        text: formatHashrate(totalHashrate)
                        font.weight: Font.Bold
                        font.pointSize: 14
                    }
                }

                // Active nodes
                Column {
                    Kirigami.Heading {
                        level: 5
                        text: "Active Nodes"
                        color: Kirigami.Theme.disabledTextColor
                    }
                    PlasmaComponents.Label {
                        text: `${activeNodes} / ${clusterNodes.split(",").length}`
                        font.weight: Font.Bold
                        font.pointSize: 14
                    }
                }
            }
        }

        // ── Per-Node Sections ──
        Repeater {
            model: clusterNodes.split(",")

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: nodeCol.height + Kirigami.Units.smallSpacing * 2
                color: Qt.rgba(1, 1, 1, 0.03)
                radius: Kirigami.Units.smallSpacing

                ColumnLayout {
                    id: nodeCol
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: Kirigami.Units.smallSpacing
                    }
                    spacing: Kirigami.Units.smallSpacing

                    property string nodeName: modelData.trim()
                    property var nd: nodeData[nodeName] || {
                        name: nodeName, xmrigHashrate: 0,
                        xmrigWorkers: 0, gpus: [], totalHashrate: 0
                    }

                    // Node header
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents.Label {
                            text: "🖥 " + nodeName
                            font.weight: Font.Bold
                            font.pointSize: 11
                        }

                        Item { Layout.fillWidth: true }

                        PlasmaComponents.Label {
                            text: nd.totalHashrate > 0
                                ? formatHashrate(nd.totalHashrate)
                                : "Idle"
                            color: nd.totalHashrate > 0
                                ? Kirigami.Theme.textColor
                                : Kirigami.Theme.disabledTextColor
                            font.weight: Font.Bold
                        }
                    }

                    // CPU mining row
                    RowLayout {
                        visible: nd.xmrigHashrate > 0
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents.Label {
                            text: "  CPU"
                            color: Kirigami.Theme.disabledTextColor
                        }
                        PlasmaComponents.Label {
                            text: `${nd.xmrigWorkers} worker(s) · ${formatHashrate(nd.xmrigHashrate)}`
                        }
                    }

                    // GPU rows
                    Repeater {
                        model: nd.gpus

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            // GPU indicator
                            Rectangle {
                                Layout.preferredWidth: 8
                                Layout.preferredHeight: 8
                                radius: 4
                                color: modelData.color
                            }

                            PlasmaComponents.Label {
                                text: modelData.name
                                font.pointSize: 9
                            }

                            Item { Layout.fillWidth: true }

                            // Hashrate
                            PlasmaComponents.Label {
                                text: formatHashrate(modelData.hashrate)
                                font.weight: Font.DemiBold
                                font.pointSize: 9
                            }

                            // Power
                            PlasmaComponents.Label {
                                visible: modelData.power !== null
                                text: formatPower(modelData.power)
                                color: Kirigami.Theme.disabledTextColor
                                font.pointSize: 9
                            }

                            // Temperature
                            PlasmaComponents.Label {
                                visible: modelData.temp !== null
                                text: formatTemp(modelData.temp)
                                color: modelData.temp > 80
                                    ? "#ff6b6b"
                                    : Kirigami.Theme.disabledTextColor
                                font.pointSize: 9
                            }
                        }
                    }
                }
            }
        }

        // ── Refresh indicator ──
        PlasmaComponents.Label {
            Layout.alignment: Qt.AlignRight
            text: `Updated: ${new Date().toLocaleTimeString(Qt.locale(), "HH:mm:ss")}`
            color: Kirigami.Theme.disabledTextColor
            font.pointSize: 8
        }
    }

    // Initial fetch
    Component.onCompleted: fetchData()
}
