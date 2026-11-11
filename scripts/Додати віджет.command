#!/bin/bash
# Реєструє віджет «Тривога UA» у macOS (якщо його немає у списку віджетів).
APP="/Applications/UA Alert.app"
if [ ! -d "$APP" ]; then
  echo "Спочатку перетягніть UA Alert у папку «Програми»."; read -n 1 -s -r -p "Натисніть будь-яку клавішу…"; exit 1
fi
echo "Знімаю карантин…";         xattr -dr com.apple.quarantine "$APP" 2>/dev/null
echo "Реєструю програму…";       /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "$APP" 2>/dev/null
echo "Реєструю віджет…";          pluginkit -a "$APP/Contents/PlugIns/UAAlertWidget.appex" 2>/dev/null
open "$APP"; sleep 3
killall chronod NotificationCenter 2>/dev/null
echo
if pluginkit -m -p com.apple.widgetkit-extension | grep -qi uaalert; then
  echo "✅ Готово. Правий клік на робочому столі → «Редагувати віджети» → «Тривога UA»."
else
  echo "⚠️ macOS поки не бачить віджет. Перезавантажте Mac і спробуйте ще раз."
fi
read -n 1 -s -r -p "Натисніть будь-яку клавішу, щоб закрити…"
