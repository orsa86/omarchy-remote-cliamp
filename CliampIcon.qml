import QtQuick
import qs.Commons

// The bar mark: a three-bar level meter, drawn (an SVG rasterises badly at bar
// size). Three states per the 1a spec — playing pulses the bars in accent,
// idle holds them still, offline flattens them to stubs.
Item {
  id: root

  property real iconSize: 16
  property color color: Color.foreground
  // Drives the eq pulse; the offline flattening is the caller dimming `color`
  // plus setting this false with `offline` true.
  property bool playing: false
  property bool offline: false

  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property var barFractions: [0.45, 0.95, 0.65]
  readonly property real barWidth: iconSize * 0.18
  readonly property real barGap: iconSize * 0.16

  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: (root.iconSize - root.iconSize * 0.95) / 2
    spacing: root.barGap

    Repeater {
      model: root.barFractions

      Rectangle {
        id: bar
        required property var modelData
        required property int index

        width: root.barWidth
        height: root.iconSize * (root.offline ? 0.2 : bar.modelData)
        radius: width / 2
        color: root.color
        anchors.bottom: parent.bottom

        transform: Scale {
          id: pulse
          origin.y: bar.height
          yScale: 1
        }

        SequentialAnimation {
          running: root.playing && root.visible
          loops: Animation.Infinite
          // Staggered like a meter breathing, per the spec: 1.2s InOutSine,
          // 0/.15/.3s delays.
          PauseAnimation { duration: bar.index * 150 }
          SequentialAnimation {
            loops: Animation.Infinite
            NumberAnimation { target: pulse; property: "yScale"; from: 1; to: 0.35; duration: 600; easing.type: Easing.InOutSine }
            NumberAnimation { target: pulse; property: "yScale"; from: 0.35; to: 1; duration: 600; easing.type: Easing.InOutSine }
          }
          onStopped: pulse.yScale = 1
        }
      }
    }
  }
}
