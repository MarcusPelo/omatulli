import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "marcuspelo.omatulli"
  ipcTarget: "marcuspelo.omatulli"

  readonly property string baseUrl: {
    var v = settings ? settings.baseUrl : undefined
    if (typeof v === "string" && v.length > 0) return v
    if (root.envBaseUrl) return root.envBaseUrl
    return "http://localhost:8181"
  }
  readonly property int pollInterval: {
    var v = settings ? settings.refreshIntervalSec : undefined
    return (typeof v === "number" && v >= 5) ? v : 10
  }
  readonly property bool maskLocation: {
    var v = settings ? settings.maskLocation : undefined
    return (typeof v === "boolean") ? v : true
  }

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property string barIcon: "▶"

  property string apiKey: ""
  property string envBaseUrl: ""
  property bool apiKeyLoaded: false

  property var sessions: []
  property int streamCount: 0
  property int directPlayCount: 0
  property int transcodeCount: 0
  property real totalBandwidth: 0
  property bool loading: false
  property bool hasError: false
  property string errorText: ""

  property var imageCache: ({})
  property var imageCacheError: ({})
  property var imageQueue: []
  property bool imageFetchBusy: false

  property string viewMode: "list"
  property string draftBaseUrl: ""
  property int draftRefreshIntervalSec: 10
  property bool draftMaskLocation: true
  property string settingsStatusText: ""

  function formatBandwidth(kbps) {
    var v = Number(kbps) || 0
    if (v <= 0) return "0 kbps"
    if (v >= 1000) return (v / 1000).toFixed(1) + " Mbps"
    return v.toFixed(0) + " kbps"
  }

  function formatDuration(ms) {
    var totalSec = Math.max(0, Math.floor((Number(ms) || 0) / 1000))
    var h = Math.floor(totalSec / 3600)
    var m = Math.floor((totalSec % 3600) / 60)
    var s = totalSec % 60
    var mm = (h > 0 && m < 10 ? "0" : "") + m
    var ss = (s < 10 ? "0" : "") + s
    return h > 0 ? (h + ":" + mm + ":" + ss) : (m + ":" + ss)
  }

  function etaText(session) {
    var duration = Number(session.duration) || 0
    var offset = Number(session.view_offset) || 0
    var remaining = Math.max(0, duration - offset)
    var eta = new Date(Date.now() + remaining)
    var hh = eta.getHours()
    var mm = eta.getMinutes()
    return (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm
  }

  function progressFraction(session) {
    var pct = Number(session.progress_percent)
    if (!isNaN(pct) && pct >= 0) return Math.max(0, Math.min(1, pct / 100))
    var duration = Number(session.duration) || 0
    if (duration <= 0) return 0
    var offset = Number(session.view_offset) || 0
    return Math.max(0, Math.min(1, offset / duration))
  }

  function decisionLabel(decision) {
    var d = String(decision || "").toLowerCase()
    if (d === "direct play") return "Direct Play"
    if (d === "copy") return "Direct Stream"
    if (d === "transcode") return "Transcode"
    return "—"
  }

  function channelLabel(layout, channels) {
    var l = String(layout || "").toLowerCase()
    if (l.indexOf("7.1") !== -1) return "7.1"
    if (l.indexOf("5.1") !== -1) return "5.1"
    if (l.indexOf("stereo") !== -1) return "Stereo"
    if (l.indexOf("mono") !== -1) return "Mono"
    var n = Number(channels)
    if (n === 1) return "Mono"
    if (n === 2) return "Stereo"
    if (n === 6) return "5.1"
    if (n === 8) return "7.1"
    return layout ? layout : (channels ? channels + "ch" : "")
  }

  function containerLine(s) {
    var decision = s.container_decision || s.transcode_decision
    var label = root.decisionLabel(decision)
    if (String(decision || "").toLowerCase() === "transcode") {
      var from = String(s.container || "").toUpperCase()
      var to = String(s.transcode_container || "").toUpperCase()
      return label + " (" + from + (to ? " → " + to : "") + ")"
    }
    return label + " (" + String(s.container || "").toUpperCase() + ")"
  }

  function videoLine(s) {
    if (!s.video_decision) return ""
    var codec = String(s.stream_video_codec || s.video_codec || "").toUpperCase()
    if (!codec) return ""
    var label = root.decisionLabel(s.video_decision)
    if (String(s.video_decision).toLowerCase() === "transcode") {
      var toCodec = String(s.transcode_video_codec || "").toUpperCase()
      return label + " (" + codec + (toCodec ? " → " + toCodec : "") + ")"
    }
    var res = s.stream_video_full_resolution || s.video_full_resolution || ""
    var range = s.stream_video_dynamic_range || s.video_dynamic_range || ""
    var parts = [codec, res, range].filter(function(p) { return !!p })
    return label + " (" + parts.join(" ") + ")"
  }

  function audioLine(s) {
    if (!s.audio_decision) return ""
    var label = root.decisionLabel(s.audio_decision)
    var lang = s.stream_audio_language || s.audio_language || ""
    var fromCodec = String(s.audio_codec || "").toUpperCase()
    var fromLayout = root.channelLabel(s.audio_channel_layout, s.audio_channels)
    var fromPart = fromCodec + (fromLayout ? " " + fromLayout : "")
    if (String(s.audio_decision).toLowerCase() === "transcode") {
      var toCodec = String(s.transcode_audio_codec || "").toUpperCase()
      var toLayout = root.channelLabel(s.stream_audio_channel_layout, s.transcode_audio_channels || s.stream_audio_channels)
      var toPart = toCodec + (toLayout ? " " + toLayout : "")
      return label + " (" + (lang ? lang + " - " : "") + fromPart + " → " + toPart + ")"
    }
    return label + " (" + (lang ? lang + " - " : "") + fromPart + ")"
  }

  function subtitleLine(s) {
    if (!s.subtitle_decision) return ""
    var label = root.decisionLabel(s.subtitle_decision)
    var lang = s.subtitle_language || ""
    var fmt = String(s.subtitle_format || s.subtitle_codec || "").toUpperCase()
    if (String(s.subtitle_decision).toLowerCase() === "transcode") {
      var to = String(s.stream_subtitle_format || "").toUpperCase()
      return label + " (" + (lang ? lang + " - " : "") + fmt + (to ? " → " + to : "") + ")"
    }
    return label + " (" + (lang ? lang + " - " : "") + fmt + ")"
  }

  function qualityLine(s) {
    var profile = s.quality_profile || "Original"
    var bitrate = Number(s.bitrate) || 0
    if (bitrate <= 0) return profile
    return profile + " (" + (bitrate / 1000).toFixed(1) + " Mbps)"
  }

  function locationLabel(s) {
    var loc = String(s.location || "").toUpperCase() || "—"
    if (root.maskLocation) return loc
    var ip = s.ip_address_public || s.ip_address || ""
    return loc + (ip ? " " + ip : "")
  }

  function mediaIcon(s) {
    var t = s.media_type
    if (t === "episode") return "📺"
    if (t === "track") return "🎵"
    if (t === "movie") return "🎬"
    if (t === "clip") return "🎞"
    if (t === "photo") return "🖼"
    return "▶"
  }

  function subtitleMeta(s) {
    if (s.media_type === "episode") {
      return "S" + (s.parent_media_index || "?") + " · E" + (s.media_index || "?")
    }
    if (s.media_type === "track") return s.parent_title || ""
    if (s.media_type === "movie") return s.year || ""
    return s.parent_title || s.year || ""
  }

  function posterPath(s) {
    if (s.media_type === "episode") return s.grandparent_thumb || s.parent_thumb || s.thumb || ""
    if (s.media_type === "track") return s.thumb || s.parent_thumb || ""
    return s.thumb || s.art || ""
  }

  function cacheDir() {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    if (xdg && xdg.length > 0) return xdg + "/omatulli"
    return Quickshell.env("HOME") + "/.cache/omatulli"
  }

  function sanitizeKey(s) {
    return String(s).replace(/[^a-zA-Z0-9]+/g, "_")
  }

  // Images are fetched via curl (apikey sent over stdin, never argv/URL — see
  // imageFetchProc) into a local cache file, and Image.source points at that
  // file. Tautulli's pms_image_proxy has no way to authenticate an inline
  // QML Image element without putting the apikey in the URL, so this proxy
  // step is what keeps the key out of network/proxy logs for posters too.
  function requestImage(remotePath, width, height) {
    if (!remotePath || !root.apiKeyLoaded || !root.apiKey) return ""
    var key = root.sanitizeKey(remotePath) + "_" + width + "x" + height
    if (root.imageCache[key]) return root.imageCache[key]
    if (root.imageCacheError[key]) return ""
    for (var i = 0; i < root.imageQueue.length; i++) {
      if (root.imageQueue[i].key === key) return ""
    }
    root.imageQueue.push({ key: key, remotePath: remotePath, width: width, height: height })
    root.pumpImageQueue()
    return ""
  }

  function pumpImageQueue() {
    if (root.imageFetchBusy || root.imageQueue.length === 0 || imageFetchProc.running) return
    root.imageFetchBusy = true
    var item = root.imageQueue.shift()
    var outFile = root.cacheDir() + "/" + item.key
    imageFetchProc.outFile = outFile
    imageFetchProc.pendingKey = item.key
    imageFetchProc.reqQuery = "apikey=" + root.apiKey + "&cmd=pms_image_proxy&img="
      + encodeURIComponent(item.remotePath) + "&width=" + item.width + "&height=" + item.height
    imageFetchProc.command = ["curl", "-fsS", "--max-time", "8", "--data", "@-", "-o", outFile, root.baseUrl + "/api/v2"]
    imageFetchProc.stdinEnabled = true
    imageFetchProc.running = true
  }

  function posterUrl(s) {
    var path = root.posterPath(s)
    if (!path) return ""
    return root.requestImage(path, 200, 300)
  }

  function stateColor(state) {
    var s = String(state || "").toLowerCase()
    if (s === "playing") return "#8fd694"
    if (s === "buffering") return "#e0af68"
    return root.dim
  }

  function statePlayIcon(state) {
    var s = String(state || "").toLowerCase()
    if (s === "paused") return "⏸"
    if (s === "buffering") return "⏳"
    return "▶"
  }

  function parseEnv(raw) {
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line || line.indexOf("#") === 0) continue
      var eq = line.indexOf("=")
      if (eq < 0) continue
      var key = line.substring(0, eq).trim()
      var value = line.substring(eq + 1).trim().replace(/^["']|["']$/g, "")
      if (key === "API_KEY") root.apiKey = value
      else if (key === "URL_BASE") root.envBaseUrl = value
    }
    apiKeyLoaded = true
  }

  function refresh() {
    if (!apiKeyLoaded) return
    if (!apiKey) {
      hasError = true
      errorText = "API key not configured in .env"
      return
    }
    if (!activityProc.running) {
      loading = true
      // apikey goes over stdin (see onStarted below), never in argv or the URL.
      activityProc.command = ["curl", "-fsS", "--max-time", "6", "--data", "@-", root.baseUrl + "/api/v2"]
      activityProc.stdinEnabled = true
      activityProc.running = true
    }
  }

  function handleActivity(raw) {
    loading = false
    try {
      var data = JSON.parse(String(raw || "")).response.data
      root.sessions = data.sessions || []
      root.streamCount = Number(data.stream_count) || 0
      root.directPlayCount = Number(data.stream_count_direct_play) || 0
      root.transcodeCount = Number(data.stream_count_transcode) || 0
      root.totalBandwidth = Number(data.total_bandwidth) || 0
      hasError = false
      errorText = ""
    } catch (e) {
      hasError = true
      errorText = "Failed to read Tautulli response"
    }
  }

  function triggerPress(button) {
    if (button === Qt.MiddleButton) { refresh(); return }
    if (opened) close(); else { open(); refresh() }
  }

  function openSettingsView() {
    root.viewMode = "settings"
    root.draftBaseUrl = root.baseUrl
    root.draftRefreshIntervalSec = root.pollInterval
    root.draftMaskLocation = root.maskLocation
    root.settingsStatusText = ""
  }

  function closeSettingsView() {
    root.viewMode = "list"
  }

  function canPersistSettings() {
    return !!(root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
  }

  function saveSettings() {
    var url = String(root.draftBaseUrl || "").trim()
    if (!url) url = root.envBaseUrl || "http://localhost:8181"
    var interval = Math.max(5, Math.min(300, Math.round(Number(root.draftRefreshIntervalSec) || 10)))
    var next = { baseUrl: url, refreshIntervalSec: interval, maskLocation: root.draftMaskLocation }

    root.draftBaseUrl = url
    root.settings = next

    if (root.canPersistSettings()) {
      root.bar.shell.updateEntryInline(root.moduleName, next)
      root.settingsStatusText = "Saved"
    } else {
      root.settingsStatusText = "Saved for this session only (bar unavailable)"
    }

    root.hasError = false
    root.errorText = ""
    root.refresh()
  }

  component InfoRow: RowLayout {
    id: infoRow
    property string label: ""
    property string value: ""
    visible: infoRow.value !== ""
    Layout.fillWidth: true
    spacing: 6

    Text {
      text: infoRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      Layout.preferredWidth: Style.space(76)
    }
    Text {
      text: infoRow.value
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      Layout.fillWidth: true
      elide: Text.ElideRight
    }
  }

  FileView {
    id: envFile
    path: Quickshell.env("HOME") + "/.config/omatulli/.env"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.parseEnv(text())
      envPermProc.command = ["chmod", "600", envFile.path]
      envPermProc.running = true
    }
    onLoadFailed: {
      root.apiKeyLoaded = true
      root.hasError = true
      root.errorText = "~/.config/omatulli/.env not found (see README)"
    }
  }

  // Enforces 0600 on the credential file every time it's (re-)loaded, since
  // it holds the Tautulli API key and nothing else guarantees its mode.
  Process {
    id: envPermProc
  }

  Process {
    id: activityProc
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleActivity(text)
    }
    onStarted: {
      activityProc.write("apikey=" + root.apiKey + "&cmd=get_activity")
      activityProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) {
        root.loading = false
        root.hasError = true
        root.errorText = "Tautulli unavailable at " + root.baseUrl
      }
    }
  }

  Process {
    id: imageFetchProc
    property string outFile: ""
    property string pendingKey: ""
    property string reqQuery: ""
    stdinEnabled: true
    onStarted: {
      imageFetchProc.write(imageFetchProc.reqQuery)
      imageFetchProc.stdinEnabled = false
    }
    onExited: function(code) {
      var key = imageFetchProc.pendingKey
      if (code === 0 && imageFetchProc.outFile) {
        var nextCache = Object.assign({}, root.imageCache)
        nextCache[key] = "file://" + imageFetchProc.outFile
        root.imageCache = nextCache
      } else {
        var nextErr = Object.assign({}, root.imageCacheError)
        nextErr[key] = true
        root.imageCacheError = nextErr
      }
      root.imageFetchBusy = false
      root.pumpImageQueue()
    }
  }

  Process {
    id: cacheSetupProc
    command: ["bash", "-c", 'mkdir -p "$1" && find "$1" -maxdepth 1 -type f -mtime +14 -delete', "omatulli", root.cacheDir()]
  }

  Component.onCompleted: cacheSetupProc.running = true

  Timer {
    id: pollTimer
    interval: root.pollInterval * 1000
    running: root.apiKeyLoaded
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    if (opened) {
      root.viewMode = "list"
      root.refresh()
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.hasError
      ? root.barIcon + " !"
      : (root.streamCount > 0 ? root.barIcon + " " + root.streamCount : root.barIcon)
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(48)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    tooltipText: root.hasError
      ? root.errorText
      : (root.streamCount > 0
        ? (root.streamCount + " stream" + (root.streamCount === 1 ? "" : "s")
          + " (" + root.directPlayCount + " direct play, " + root.transcodeCount + " transcode)"
          + "\n" + root.formatBandwidth(root.totalBandwidth))
        : "No active streams")
    onPressed: function(b) { root.triggerPress(b) }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: baseUrlField.activeFocus
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }
    }

    ColumnLayout {
      id: contentColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(10)

      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Text {
          text: root.barIcon + "  " + (root.viewMode === "settings" ? "Settings" : "Tautulli Activity")
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          Layout.fillWidth: true
        }

        Button {
          visible: root.viewMode === "list"
          text: root.loading ? "Refreshing…" : "Refresh"
          foreground: root.fg
          tooltipText: "Refresh now"
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          active: root.loading
          onClicked: root.refresh()
        }

        Button {
          visible: root.viewMode === "list"
          text: "⚙"
          foreground: root.fg
          tooltipText: "Settings"
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.openSettingsView()
        }

        Button {
          visible: root.viewMode === "settings"
          text: "Back"
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.closeSettingsView()
        }
      }

      ColumnLayout {
        visible: root.viewMode === "settings"
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          text: "Tautulli base URL"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        TextField {
          id: baseUrlField
          Layout.fillWidth: true
          placeholderText: "http://localhost:8181"
          foreground: root.fg
          text: root.draftBaseUrl
          onTextChanged: root.draftBaseUrl = text
        }

        NumberField {
          label: "Refresh interval (seconds)"
          value: root.draftRefreshIntervalSec
          from: 5
          to: 300
          stepSize: 5
          foreground: root.fg
          accent: Color.accent
          fontFamily: root.fontFamily
          onModified: function(v) { root.draftRefreshIntervalSec = v }
        }

        RowLayout {
          spacing: 8
          ToggleSwitch {
            foreground: root.fg
            accent: Color.accent
            checked: root.draftMaskLocation
            onToggled: root.draftMaskLocation = !root.draftMaskLocation
          }
          Text {
            text: "Hide public IP (show WAN/LAN only)"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          visible: root.settingsStatusText !== ""
          Layout.fillWidth: true
          text: root.settingsStatusText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Button {
          text: "Save"
          foreground: root.fg
          accent: Color.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.saveSettings()
        }

        Text {
          Layout.fillWidth: true
          text: "The API key stays in ~/.config/omatulli/.env and is not editable here."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          text: "Tip: disabling and re-enabling the plugin resets this field. Add URL_BASE=... to ~/.config/omatulli/.env to keep a fallback that survives that."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ColumnLayout {
        visible: root.viewMode === "list"
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          Layout.fillWidth: true
          visible: !root.hasError
          text: root.streamCount + " stream" + (root.streamCount === 1 ? "" : "s")
            + (root.streamCount > 0 ? (" (" + root.directPlayCount + " direct play, " + root.transcodeCount + " transcode)") : "")
            + " · " + root.formatBandwidth(root.totalBandwidth)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: root.hasError
          Layout.fillWidth: true
          text: root.errorText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          visible: !root.hasError && root.sessions.length === 0
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: root.loading ? "Loading…" : "No active streams"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ListView {
          id: sessionList
          visible: !root.hasError && root.sessions.length > 0
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(sessionList.contentHeight, Style.space(520))
          clip: true
          spacing: Style.space(10)
          model: root.sessions
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: ColumnLayout {
            id: card
            required property var modelData
            width: sessionList.width
            height: implicitHeight

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: cardInner.implicitHeight + Style.space(16)
              radius: Style.space(8)
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
              border.width: 1
              border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

              ColumnLayout {
                id: cardInner
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(6)

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(10)

                  Rectangle {
                    Layout.preferredWidth: 64
                    Layout.preferredHeight: card.modelData.media_type === "track" ? 64 : 96
                    Layout.alignment: Qt.AlignTop
                    radius: Style.space(4)
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                    clip: true

                    Image {
                      anchors.fill: parent
                      source: root.posterUrl(card.modelData)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                      smooth: true
                    }
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                      Layout.fillWidth: true
                      text: card.modelData.full_title || card.modelData.title || "Unknown"
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      visible: root.subtitleMeta(card.modelData) !== ""
                      text: root.mediaIcon(card.modelData) + "  " + root.subtitleMeta(card.modelData)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    InfoRow { label: "PRODUCT"; value: card.modelData.product || "" }
                    InfoRow { label: "PLAYER"; value: card.modelData.player || "" }
                    InfoRow { label: "STREAM"; value: root.decisionLabel(card.modelData.transcode_decision) }
                    InfoRow { label: "CONTAINER"; value: root.containerLine(card.modelData) }
                    InfoRow { label: "VIDEO"; value: root.videoLine(card.modelData) }
                    InfoRow { label: "AUDIO"; value: root.audioLine(card.modelData) }
                    InfoRow { label: "SUBTITLE"; value: root.subtitleLine(card.modelData) }
                    InfoRow { label: "QUALITY"; value: root.qualityLine(card.modelData) }
                    InfoRow { label: "LOCATION"; value: root.locationLabel(card.modelData) }
                  }
                }

                Rectangle {
                  Layout.fillWidth: true
                  height: 4
                  radius: 2
                  color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)

                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * root.progressFraction(card.modelData)
                    radius: 2
                    color: root.stateColor(card.modelData.state)
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6

                  Text {
                    text: root.statePlayIcon(card.modelData.state)
                    color: root.stateColor(card.modelData.state)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Rectangle {
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    radius: 8
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                    clip: true

                    Image {
                      anchors.fill: parent
                      source: card.modelData.user_thumb || ""
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    text: card.modelData.friendly_name || card.modelData.user || ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  Text {
                    text: String(card.modelData.state || "").toLowerCase() === "playing"
                      ? ("ETA " + root.etaText(card.modelData))
                      : (String(card.modelData.state || "").toLowerCase() === "paused" ? "Paused" : "Buffering")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  Layout.fillWidth: true
                  horizontalAlignment: Text.AlignRight
                  text: root.formatDuration(Number(card.modelData.view_offset) || 0) + " / " + root.formatDuration(Number(card.modelData.duration) || 0)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }

      Text {
        Layout.fillWidth: true
        Layout.topMargin: 4
        text: "r refresh · esc close"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
