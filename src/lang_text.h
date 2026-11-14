/* Every text the user sees, in every language. One row per text:
 *   X(name, 简体中文, 繁體中文, English, 日本語, 한국어, Français, Deutsch, Español)
 * Included several times with different X (lang.h: the numbers S_<name>; lang.c: the
 * texts; lang.inc: the numbers for the assembly). Each program has its own rows:
 * sniplite.com (CONSOLE), the installer (SETUP), sniplite.exe (neither).
 * A row's texts take the same % arguments in the same order. */

#if defined(CONSOLE)

X(HELP,
  "：又快又轻的截图工具\n"
  "\n"
  "  sniplite                     启动（已启动就看状态）\n"
  "  sniplite capture             开始截图，和按 F1 一样\n"
  "  sniplite capture --full --out a.png        整个屏幕存成文件\n"
  "  sniplite capture --rect 0,0,800,600        截这块区域到剪贴板\n"
  "  sniplite pin [图片]          贴到屏幕，不给图片就贴剪贴板\n"
  "  sniplite settings            打开首选项\n"
  "  sniplite update              检查更新，加 --install 直接装上新版本\n"
  "  sniplite status              看状态\n"
  "  sniplite quit                退出\n"
  "\n"
  "小提示：\n"
  "  capture 还能加 --clip（复制）、--pin（贴图），可以一起用\n"
  "  start 可以临时换热键：--hotkey Ctrl+Alt+A（另有 --pin-hotkey、--toggle-hotkey）\n"
  "  start --gdi 用省内存的截屏方式，--dxgi 换回最快的\n"
  "  任何命令加 --json，输出给程序读\n"
  "\n"
  "退出码：0 成功，1 失败，2 参数不对，3 没在运行，4 没东西可贴，5 热键被占用\n",

  "：又快又輕的截圖工具\n"
  "\n"
  "  sniplite                     啟動（已啟動就看狀態）\n"
  "  sniplite capture             開始截圖，和按 F1 一樣\n"
  "  sniplite capture --full --out a.png        整個螢幕存成檔案\n"
  "  sniplite capture --rect 0,0,800,600        截這塊區域到剪貼簿\n"
  "  sniplite pin [圖片]          貼到螢幕，不給圖片就貼剪貼簿\n"
  "  sniplite settings            開啟偏好設定\n"
  "  sniplite update              檢查更新，加 --install 直接裝上新版本\n"
  "  sniplite status              看狀態\n"
  "  sniplite quit                結束\n"
  "\n"
  "小提示：\n"
  "  capture 還能加 --clip（複製）、--pin（貼圖），可以一起用\n"
  "  start 可以臨時換快速鍵：--hotkey Ctrl+Alt+A（另有 --pin-hotkey、--toggle-hotkey）\n"
  "  start --gdi 用省記憶體的截圖方式，--dxgi 換回最快的\n"
  "  任何指令加 --json，輸出給程式讀\n"
  "\n"
  "結束代碼：0 成功，1 失敗，2 參數不對，3 沒在執行，4 沒東西可貼，5 快速鍵被佔用\n",

  ": fast, light screenshots\n"
  "\n"
  "  sniplite                     start (shows the status if already running)\n"
  "  sniplite capture             start a capture, like pressing F1\n"
  "  sniplite capture --full --out a.png        save the whole screen to a file\n"
  "  sniplite capture --rect 0,0,800,600        copy that area to the clipboard\n"
  "  sniplite pin [image]         pin an image, or the clipboard without one\n"
  "  sniplite settings            open Settings\n"
  "  sniplite update              check for updates; --install installs the new version\n"
  "  sniplite status              show the status\n"
  "  sniplite quit                quit\n"
  "\n"
  "Tips:\n"
  "  capture also takes --clip (copy) and --pin (pin), together if you like\n"
  "  start can set hotkeys for this run: --hotkey Ctrl+Alt+A (also --pin-hotkey, --toggle-hotkey)\n"
  "  start --gdi uses the low-memory capture mode, --dxgi goes back to the fastest\n"
  "  add --json to any command for output a program can read\n"
  "\n"
  "Exit codes: 0 ok, 1 failed, 2 bad arguments, 3 not running, 4 nothing to pin, 5 hotkey in use\n",

  "：軽くて速いスクリーンショットツール\n"
  "\n"
  "  sniplite                     起動（起動済みなら状態を表示）\n"
  "  sniplite capture             キャプチャ開始（F1 と同じ）\n"
  "  sniplite capture --full --out a.png        画面全体をファイルに保存\n"
  "  sniplite capture --rect 0,0,800,600        この範囲をクリップボードにコピー\n"
  "  sniplite pin [画像]          画像をピン留め（省略時はクリップボード）\n"
  "  sniplite settings            設定を開く\n"
  "  sniplite update              更新を確認（--install で新バージョンをインストール）\n"
  "  sniplite status              状態を表示\n"
  "  sniplite quit                終了\n"
  "\n"
  "ヒント：\n"
  "  capture には --clip（コピー）と --pin（ピン留め）も付けられます（併用可）\n"
  "  start でホットキーを一時変更：--hotkey Ctrl+Alt+A（--pin-hotkey、--toggle-hotkey も）\n"
  "  start --gdi は省メモリ方式、--dxgi で最速の方式に戻します\n"
  "  どのコマンドも --json でプログラム向けの出力になります\n"
  "\n"
  "終了コード：0 成功、1 失敗、2 引数エラー、3 未起動、4 ピン留め対象なし、5 ホットキー使用中\n",

  ": 가볍고 빠른 화면 캡처 도구\n"
  "\n"
  "  sniplite                     시작 (실행 중이면 상태 표시)\n"
  "  sniplite capture             캡처 시작 (F1과 같음)\n"
  "  sniplite capture --full --out a.png        전체 화면을 파일로 저장\n"
  "  sniplite capture --rect 0,0,800,600        이 영역을 클립보드에 복사\n"
  "  sniplite pin [이미지]        화면에 고정 (이미지가 없으면 클립보드)\n"
  "  sniplite settings            설정 열기\n"
  "  sniplite update              업데이트 확인 (--install로 새 버전 설치)\n"
  "  sniplite status              상태 표시\n"
  "  sniplite quit                종료\n"
  "\n"
  "팁:\n"
  "  capture에 --clip(복사), --pin(고정)을 함께 쓸 수 있습니다\n"
  "  start로 단축키를 임시 변경: --hotkey Ctrl+Alt+A (--pin-hotkey, --toggle-hotkey도 가능)\n"
  "  start --gdi는 메모리 절약 방식을 쓰고, --dxgi는 가장 빠른 방식으로 되돌립니다\n"
  "  어떤 명령이든 --json을 붙이면 프로그램용 출력이 됩니다\n"
  "\n"
  "종료 코드: 0 성공, 1 실패, 2 잘못된 인수, 3 실행 중 아님, 4 고정할 것 없음, 5 단축키 사용 중\n",

  " : des captures d'écran rapides et légères\n"
  "\n"
  "  sniplite                     démarrer (ou afficher l'état si déjà lancé)\n"
  "  sniplite capture             lancer une capture, comme avec F1\n"
  "  sniplite capture --full --out a.png        enregistrer tout l'écran dans un fichier\n"
  "  sniplite capture --rect 0,0,800,600        copier cette zone dans le presse-papiers\n"
  "  sniplite pin [image]         épingler une image, sinon le presse-papiers\n"
  "  sniplite settings            ouvrir les préférences\n"
  "  sniplite update              chercher une mise à jour ; --install l'installe\n"
  "  sniplite status              afficher l'état\n"
  "  sniplite quit                quitter\n"
  "\n"
  "Astuces :\n"
  "  capture accepte aussi --clip (copier) et --pin (épingler), ensemble si besoin\n"
  "  start peut changer les raccourcis pour cette fois : --hotkey Ctrl+Alt+A (aussi --pin-hotkey, --toggle-hotkey)\n"
  "  start --gdi choisit la capture économe en mémoire, --dxgi revient à la plus rapide\n"
  "  ajoutez --json à une commande pour une sortie lisible par un programme\n"
  "\n"
  "Codes de sortie : 0 succès, 1 échec, 2 arguments invalides, 3 non lancé, 4 rien à épingler, 5 raccourci déjà pris\n",

  ": schnelles, schlankes Screenshot-Tool\n"
  "\n"
  "  sniplite                     starten (zeigt den Status, wenn es schon läuft)\n"
  "  sniplite capture             Aufnahme starten, wie mit F1\n"
  "  sniplite capture --full --out a.png        ganzen Bildschirm in eine Datei speichern\n"
  "  sniplite capture --rect 0,0,800,600        diesen Bereich in die Zwischenablage kopieren\n"
  "  sniplite pin [Bild]          Bild anheften, ohne Bild die Zwischenablage\n"
  "  sniplite settings            Einstellungen öffnen\n"
  "  sniplite update              nach Updates suchen; --install installiert die neue Version\n"
  "  sniplite status              Status anzeigen\n"
  "  sniplite quit                beenden\n"
  "\n"
  "Tipps:\n"
  "  capture kennt auch --clip (kopieren) und --pin (anheften), auch zusammen\n"
  "  start kann Tastenkürzel für diesen Lauf setzen: --hotkey Ctrl+Alt+A (auch --pin-hotkey, --toggle-hotkey)\n"
  "  start --gdi nimmt den sparsamen Aufnahmemodus, --dxgi wieder den schnellsten\n"
  "  mit --json liefert jeder Befehl eine Ausgabe für Programme\n"
  "\n"
  "Exitcodes: 0 ok, 1 Fehler, 2 falsche Argumente, 3 läuft nicht, 4 nichts zum Anheften, 5 Tastenkürzel belegt\n",

  ": capturas de pantalla rápidas y ligeras\n"
  "\n"
  "  sniplite                     iniciar (o ver el estado si ya está en ejecución)\n"
  "  sniplite capture             iniciar una captura, como con F1\n"
  "  sniplite capture --full --out a.png        guardar toda la pantalla en un archivo\n"
  "  sniplite capture --rect 0,0,800,600        copiar esa zona al portapapeles\n"
  "  sniplite pin [imagen]        fijar una imagen o, sin ella, el portapapeles\n"
  "  sniplite settings            abrir los ajustes\n"
  "  sniplite update              buscar actualizaciones; --install instala la nueva versión\n"
  "  sniplite status              ver el estado\n"
  "  sniplite quit                salir\n"
  "\n"
  "Consejos:\n"
  "  capture también admite --clip (copiar) y --pin (fijar), juntos si quieres\n"
  "  start puede cambiar los atajos para esta vez: --hotkey Ctrl+Alt+A (también --pin-hotkey, --toggle-hotkey)\n"
  "  start --gdi usa el modo ligero, --dxgi vuelve al rápido\n"
  "  añade --json a cualquier comando para una salida legible por programas\n"
  "\n"
  "Códigos de salida: 0 correcto, 1 error, 2 argumentos incorrectos, 3 no iniciado, 4 nada que fijar, 5 atajo en uso\n")

X(NO_EXE,
  "找不到 sniplite.exe，它必须和 sniplite.com 放在同一个文件夹里\n",
  "找不到 sniplite.exe，它必須和 sniplite.com 放在同一個資料夾裡\n",
  "sniplite.exe not found. It must be in the same folder as sniplite.com\n",
  "sniplite.exe が見つかりません。sniplite.com と同じフォルダーに置いてください\n",
  "sniplite.exe를 찾을 수 없습니다. sniplite.com과 같은 폴더에 있어야 합니다\n",
  "sniplite.exe introuvable. Il doit être dans le même dossier que sniplite.com\n",
  "sniplite.exe nicht gefunden. Es muss im selben Ordner wie sniplite.com liegen\n",
  "No se encuentra sniplite.exe. Debe estar en la misma carpeta que sniplite.com\n")
X(CANNOT_START,
  "无法启动 sniplite.exe\n", "無法啟動 sniplite.exe\n", "Cannot start sniplite.exe\n",
  "sniplite.exe を起動できません\n", "sniplite.exe를 시작할 수 없습니다\n",
  "Impossible de lancer sniplite.exe\n", "sniplite.exe lässt sich nicht starten\n",
  "No se puede iniciar sniplite.exe\n")
X(START_FAILED,
  "sniplite.exe 没有正常启动\n", "sniplite.exe 沒有正常啟動\n", "sniplite.exe did not start properly\n",
  "sniplite.exe が正常に起動しませんでした\n", "sniplite.exe가 제대로 시작되지 않았습니다\n",
  "sniplite.exe n'a pas démarré correctement\n", "sniplite.exe ist nicht richtig gestartet\n",
  "sniplite.exe no se inició correctamente\n")
X(UPD_USAGE,
  "用法：sniplite update [--install] [--json]\n", "用法：sniplite update [--install] [--json]\n",
  "Usage: sniplite update [--install] [--json]\n", "使い方：sniplite update [--install] [--json]\n",
  "사용법: sniplite update [--install] [--json]\n", "Usage : sniplite update [--install] [--json]\n",
  "Aufruf: sniplite update [--install] [--json]\n", "Uso: sniplite update [--install] [--json]\n")
X(DOWNLOADING,
  "正在下载新版本...\n", "正在下載新版本...\n", "Downloading the new version...\n",
  "新バージョンをダウンロード中...\n", "새 버전 다운로드 중...\n",
  "Téléchargement de la nouvelle version...\n", "Neue Version wird heruntergeladen...\n",
  "Descargando la nueva versión...\n")
X(UPDATED,
  "已更新到 %s\n", "已更新到 %s\n", "Updated to %s\n", "%s に更新しました\n", "업데이트 완료: %s\n",
  "Mis à jour vers %s\n", "Auf %s aktualisiert\n", "Actualizado a %s\n")
X(PORTABLE,
  "有新版本 %s。这份 sniplite 不是用安装包装的，请到 GitHub 下载\n",
  "有新版本 %s。這份 sniplite 不是用安裝程式裝的，請到 GitHub 下載\n",
  "New version %s. This copy was not set up by the installer: get it from GitHub\n",
  "新バージョン %s があります。この sniplite はインストーラー版ではないため、GitHub から入手してください\n",
  "새 버전 %s. 이 sniplite는 설치 프로그램으로 설치되지 않았습니다. GitHub에서 받으세요\n",
  "Nouvelle version %s, à télécharger sur GitHub (copie sans installeur)\n",
  "Neue Version %s. Diese Kopie stammt nicht vom Installer: bitte von GitHub herunterladen\n",
  "Nueva versión %s. Esta copia no se instaló con el instalador: descárgala en GitHub\n")
X(NET_FAILED,
  "检查失败，请检查网络\n", "檢查失敗，請確認網路\n", "Check failed. Is the network up?\n",
  "確認に失敗しました。ネットワークを確認してください\n", "확인 실패. 네트워크를 확인하세요\n",
  "Échec de la recherche. Vérifiez le réseau\n", "Suche fehlgeschlagen. Netzwerk prüfen\n",
  "Error al buscar. Revisa la conexión\n")
X(UPD_FAILED,
  "更新失败，请稍后再试\n", "更新失敗，請稍後再試\n", "Update failed. Try again later\n",
  "更新に失敗しました。後でもう一度お試しください\n", "업데이트 실패. 나중에 다시 시도하세요\n",
  "Échec de la mise à jour. Réessayez plus tard\n", "Update fehlgeschlagen. Später erneut versuchen\n",
  "Error al actualizar. Inténtalo más tarde\n")
X(NEWER,
  "有新版本 %s（现在是 %s），运行 sniplite update --install 安装\n",
  "有新版本 %s（現在是 %s），執行 sniplite update --install 安裝\n",
  "New version %s (this is %s). Run sniplite update --install to install it\n",
  "新バージョン %s があります（現在は %s）。sniplite update --install でインストールできます\n",
  "새 버전 %s (현재 %s). sniplite update --install로 설치하세요\n",
  "Nouvelle version %s (actuelle : %s). Lancez sniplite update --install pour l'installer\n",
  "Neue Version %s (installiert: %s). Mit sniplite update --install installieren\n",
  "Nueva versión %s (actual: %s). Ejecuta sniplite update --install para instalarla\n")
X(NO_RELEASE,
  "还没有发布的版本\n", "還沒有發布的版本\n", "No release yet\n", "まだリリースがありません\n",
  "아직 공개된 버전이 없습니다\n", "Aucune version publiée\n", "Noch keine Version veröffentlicht\n",
  "Aún no hay versiones\n")
X(LATEST,
  "已是最新版本 %s\n", "已是最新版本 %s\n", "%s is the latest version\n", "%s は最新バージョンです\n",
  "최신 버전입니다 (%s)\n", "%s est la dernière version\n", "%s ist die neueste Version\n",
  "%s es la última versión\n")
X(NOT_RUNNING,
  "sniplite 没有在运行\n", "sniplite 沒有在執行\n", "sniplite is not running\n",
  "sniplite は起動していません\n", "sniplite가 실행 중이 아닙니다\n", "sniplite n'est pas lancé\n",
  "sniplite läuft nicht\n", "sniplite no está en ejecución\n")
X(NO_CONNECT,
  "无法连接 sniplite 后台进程\n", "無法連線到 sniplite 背景處理程序\n",
  "Cannot reach the sniplite background process\n", "sniplite のバックグラウンドプロセスに接続できません\n",
  "sniplite 백그라운드 프로세스에 연결할 수 없습니다\n",
  "Impossible de joindre le processus d'arrière-plan de sniplite\n",
  "Der Hintergrundprozess von sniplite ist nicht erreichbar\n",
  "No se puede conectar con el proceso en segundo plano de sniplite\n")

#elif defined(SETUP)

X(FONT, "Microsoft YaHei UI", "Microsoft JhengHei UI", "Segoe UI", "Yu Gothic UI", "Malgun Gothic", "Segoe UI",
  "Segoe UI", "Segoe UI")
X(S_CAPTION,
  "安装 sniplite", "安裝 sniplite", "Install sniplite", "sniplite のインストール", "sniplite 설치",
  "Installer sniplite", "sniplite installieren", "Instalar sniplite")
X(S_SUB,
  "极度轻量的快速截图贴图工具", "極度輕量的快速截圖貼圖工具", "A tiny, fast screenshot and pin tool",
  "超軽量で高速なスクリーンショット＆ピン留めツール", "아주 가볍고 빠른 화면 캡처, 고정 도구",
  "Captures et épingles, ultralégères et rapides", "Winzig und schnell: Screenshots und Pins",
  "Capturar y fijar, rápido y ultraligero")
X(S_PATH,
  "安装到 %s", "安裝到 %s", "Install to %s", "インストール先：%s", "설치 위치: %s", "Installer dans %s",
  "Installieren in %s", "Instalar en %s")
X(S_AUTOSTART,
  "开机启动", "開機啟動", "Start with Windows", "Windows 起動時に実行", "Windows 시작 시 실행",
  "Lancer au démarrage", "Mit Windows starten", "Iniciar con Windows")
X(S_INSTALL, "安装", "安裝", "Install", "インストール", "설치", "Installer", "Installieren", "Instalar")
X(S_CANCEL, "取消", "取消", "Cancel", "キャンセル", "취소", "Annuler", "Abbrechen", "Cancelar")
X(S_DONE_OWN,
  "装好了，sniplite 已在后台运行。", "裝好了，sniplite 已在背景執行。",
  "Done. sniplite is running in the background.", "完了しました。sniplite はバックグラウンドで実行中です。",
  "설치 완료. sniplite가 백그라운드에서 실행 중입니다.", "C'est prêt. sniplite tourne en arrière-plan.",
  "Fertig. sniplite läuft im Hintergrund.", "Listo. sniplite se ejecuta en segundo plano.")
X(S_DONE,
  "装好了，按 F1 截图，按 F3 贴图。", "裝好了，按 F1 截圖，按 F3 貼圖。",
  "Done. Press F1 to capture, F3 to pin.", "完了しました。F1 でキャプチャ、F3 でピン留めできます。",
  "설치 완료. 캡처는 F1, 고정은 F3입니다.", "C'est prêt. F1 pour capturer, F3 pour épingler.",
  "Fertig. F1 zum Aufnehmen, F3 zum Anheften.", "Listo. F1 para capturar, F3 para fijar.")
X(S_FINISH, "完成", "完成", "Finish", "完了", "완료", "Terminer", "Fertig", "Finalizar")
X(S_FAILED,
  "安装失败：无法写入程序文件。", "安裝失敗：無法寫入程式檔案。",
  "Install failed: cannot write the program files.",
  "インストールに失敗しました。プログラムファイルを書き込めません。",
  "설치 실패: 프로그램 파일을 쓸 수 없습니다.",
  "Échec de l'installation : impossible d'écrire les fichiers du programme.",
  "Installation fehlgeschlagen: Programmdateien lassen sich nicht schreiben.",
  "Error al instalar: no se pueden escribir los archivos del programa.")
/* also the name of the Start menu shortcut (install.h) */
X(UNINST_TITLE,
  "卸载 sniplite", "解除安裝 sniplite", "Uninstall sniplite", "sniplite のアンインストール", "sniplite 제거",
  "Désinstaller sniplite", "sniplite deinstallieren", "Desinstalar sniplite")

#else

/* the font of every window and of the text drawn on screenshots and pins */
X(FONT, "Microsoft YaHei UI", "Microsoft JhengHei UI", "Segoe UI", "Yu Gothic UI", "Malgun Gothic", "Segoe UI",
  "Segoe UI", "Segoe UI")

/* ---- replies to commands (main.c) ---- */
X(ERR_MISSING_VALUE,
  "%s 后面缺少参数值\n", "%s 後面缺少參數值\n", "%s needs a value\n", "%s に値がありません\n",
  "%s 뒤에 값이 없습니다\n", "%s : valeur manquante\n", "%s braucht einen Wert\n", "%s necesita un valor\n")
X(ERR_UNKNOWN_ARG,
  "不认识的参数：%s（用 sniplite help 查看用法）\n", "未知的參數：%s（用 sniplite help 查看用法）\n",
  "Unknown option: %s (see sniplite help)\n", "不明なオプション：%s（使い方は sniplite help）\n",
  "알 수 없는 옵션: %s (sniplite help 참고)\n", "Option inconnue : %s (voir sniplite help)\n",
  "Unbekannte Option: %s (siehe sniplite help)\n", "Opción desconocida: %s (ver sniplite help)\n")
X(ERR_BAD_HOTKEY,
  "无法识别的热键：%s（例：F1、Ctrl+Alt+A、Shift+F3、none）\n",
  "無法辨識的快速鍵：%s（例：F1、Ctrl+Alt+A、Shift+F3、none）\n",
  "Bad hotkey: %s (e.g. F1, Ctrl+Alt+A, Shift+F3, none)\n",
  "無効なホットキー：%s（例：F1、Ctrl+Alt+A、Shift+F3、none）\n",
  "잘못된 단축키: %s (예: F1, Ctrl+Alt+A, Shift+F3, none)\n",
  "Raccourci invalide : %s (ex. F1, Ctrl+Alt+A, Shift+F3, none)\n",
  "Ungültiges Tastenkürzel: %s (z. B. F1, Ctrl+Alt+A, Shift+F3, none)\n",
  "Atajo no válido: %s (p. ej. F1, Ctrl+Alt+A, Shift+F3, none)\n")
X(ERR_GDI_DXGI,
  "--gdi 和 --dxgi 只能选一个\n", "--gdi 和 --dxgi 只能選一個\n", "Use --gdi or --dxgi, not both\n",
  "--gdi と --dxgi は同時に使えません\n", "--gdi와 --dxgi는 함께 쓸 수 없습니다\n",
  "--gdi ou --dxgi, pas les deux\n", "Nur --gdi oder --dxgi, nicht beides\n", "Usa --gdi o --dxgi, no ambos\n")
/* status: the three hotkey labels in the order of HK_*, at most 15 columns wide */
X(ST_HK_CAPTURE,
  "截图热键", "截圖快速鍵", "Capture key", "キャプチャキー", "캡처 단축키", "Touche capture", "Aufnahmetaste",
  "Atajo capturar")
X(ST_HK_PIN,
  "贴图热键", "貼圖快速鍵", "Pin key", "ピン留めキー", "고정 단축키", "Touche épingle", "Pin-Taste",
  "Atajo fijar")
X(ST_HK_TOGGLE,
  "显示/隐藏贴图", "隱藏/顯示貼圖", "Show/hide pins", "ピン表示切替", "고정 표시/숨김", "Voir/masquer",
  "Pins ein/aus", "Ver/ocultar")
X(ST_RUNNING,
  "sniplite %s 正在后台运行（PID %lu）\n", "sniplite %s 正在背景執行（PID %lu）\n",
  "sniplite %s is running (PID %lu)\n", "sniplite %s 実行中（PID %lu）\n", "sniplite %s 실행 중 (PID %lu)\n",
  "sniplite %s est lancé (PID %lu)\n", "sniplite %s läuft (PID %lu)\n", "sniplite %s en ejecución (PID %lu)\n")
X(UNSET, "未设置", "未設定", "None", "未設定", "없음", "Aucun", "Nicht belegt", "Sin asignar")
X(ST_HK_FAILED,
  "（注册失败：可能已被其他程序占用）", "（註冊失敗：可能已被其他程式佔用）",
  " (failed: another app may be using it)", "（登録失敗：他のアプリが使用中かもしれません）",
  " (등록 실패: 다른 앱이 사용 중일 수 있음)", " (échec : peut-être pris par une autre appli)",
  " (fehlgeschlagen: evtl. von anderer App belegt)", " (falló: puede que lo use otra app)")
X(ST_BACKEND,
  "截屏方式", "截圖方式", "Capture mode", "キャプチャ方式", "캡처 방식", "Mode capture", "Aufnahmemodus",
  "Modo de captura")
X(ST_DXGI,
  "DXGI 显卡直读", "DXGI 顯示卡直讀", "DXGI (GPU)", "DXGI（GPU 直接取得）", "DXGI (GPU)", "DXGI (GPU)",
  "DXGI (GPU)", "DXGI (GPU)")
X(ST_DXGI_STARTING,
  "DXGI 初始化中", "DXGI 初始化中", "DXGI starting", "DXGI 初期化中", "DXGI 초기화 중", "DXGI démarre",
  "DXGI startet", "Iniciando DXGI")
X(ST_PINS, "贴图数量", "貼圖數量", "Pins", "ピンの数", "고정 이미지 수", "Épingles", "Pins", "Fijadas")
X(ST_LAST,
  "上次截图", "上次截圖", "Last capture", "前回", "마지막 캡처", "Dernière fois", "Letzte Aufnahme",
  "Última captura")
/* "<1> 12.3 <2> 4.5 <3> 6.7 <4>" */
X(ST_LAST_1,
  "热键到画面出现 ", "快速鍵到畫面出現 ", "key to screen ", "キーから表示まで ", "키 입력부터 표시까지 ",
  "de la touche à l'écran ", "Taste bis Bild ", "de tecla a pantalla ")
X(ST_LAST_2, " ms（抓屏 ", " ms（擷取 ", " ms (grab ", " ms（取得 ", " ms (캡처 ", " ms (capture ", " ms (Erfassen ",
  " ms (captura ")
X(ST_LAST_3, "，绘制 ", "，繪製 ", ", draw ", "、描画 ", ", 그리기 ", ", dessin ", ", Zeichnen ", ", dibujo ")
X(ST_LAST_4, "）\n", "）\n", ")\n", "）\n", ")\n", ")\n", ")\n", ")\n")
/* tray icon tooltip */
X(TRAY_CAPTURE,
  "\n截屏 %s", "\n截圖 %s", "\nCapture %s", "\nキャプチャ %s", "\n캡처 %s", "\nCapturer %s", "\nAufnehmen %s",
  "\nCapturar %s")
X(TRAY_PIN,
  "\n贴图 %s", "\n貼圖 %s", "\nPin %s", "\nピン留め %s", "\n고정 %s", "\nÉpingler %s", "\nAnheften %s",
  "\nFijar %s")
X(UPD_BALLOON_TITLE,
  "sniplite 有新版本", "sniplite 有新版本", "sniplite update", "sniplite の新バージョン", "sniplite 새 버전",
  "Mise à jour de sniplite", "sniplite-Update", "Actualización de sniplite")
X(UPD_BALLOON_TEXT,
  "%s 已发布，点这里更新。", "%s 已發布，點這裡更新。", "%s is out. Click to update.",
  "%s が公開されました。クリックで更新できます。", "%s 출시. 클릭하여 업데이트하세요.",
  "%s est disponible. Cliquez pour mettre à jour.", "%s ist da. Zum Aktualisieren klicken.",
  "%s disponible. Haz clic para actualizar.")
X(CAP_FAILED,
  "截屏失败\n", "截圖失敗\n", "Capture failed\n", "キャプチャに失敗しました\n", "캡처 실패\n",
  "Échec de la capture\n", "Aufnahme fehlgeschlagen\n", "Error al capturar\n")
X(CAP_OUTSIDE,
  "区域不在屏幕范围内\n", "區域不在螢幕範圍內\n", "The area is off screen\n", "範囲が画面の外です\n",
  "영역이 화면 밖입니다\n", "Zone hors de l'écran\n", "Bereich liegt außerhalb des Bildschirms\n",
  "Zona fuera de la pantalla\n")
X(NO_MEMORY,
  "内存不足\n", "記憶體不足\n", "Out of memory\n", "メモリ不足\n", "메모리 부족\n", "Mémoire insuffisante\n",
  "Zu wenig Speicher\n", "Memoria insuficiente\n")
/* "<1> 4.5 <2>" */
X(CAP_DONE_1,
  "已截取 %d×%d（抓屏 ", "已截圖 %d×%d（擷取 ", "Captured %d×%d (grab ", "%d×%d をキャプチャしました（取得 ",
  "%d×%d 캡처됨 (캡처 ", "Capturé %d×%d (capture ", "%d×%d aufgenommen (Erfassen ", "Capturado %d×%d (captura ")
X(CAP_DONE_2, " ms）\n", " ms）\n", " ms)\n", " ms）\n", " ms)\n", " ms)\n", " ms)\n", " ms)\n")
X(SAVED,
  "已保存：%s\n", "已儲存：%s\n", "Saved: %s\n", "保存しました：%s\n", "저장됨: %s\n", "Enregistré : %s\n",
  "Gespeichert: %s\n", "Guardado: %s\n")
X(SAVE_FAILED,
  "保存失败：%s\n", "儲存失敗：%s\n", "Save failed: %s\n", "保存に失敗しました：%s\n", "저장 실패: %s\n",
  "Échec de l'enregistrement : %s\n", "Speichern fehlgeschlagen: %s\n", "Error al guardar: %s\n")
X(COPIED,
  "已复制到剪贴板\n", "已複製到剪貼簿\n", "Copied to the clipboard\n", "クリップボードにコピーしました\n",
  "클립보드에 복사됨\n", "Copié dans le presse-papiers\n", "In die Zwischenablage kopiert\n",
  "Copiado al portapapeles\n")
X(COPY_FAILED,
  "复制到剪贴板失败\n", "複製到剪貼簿失敗\n", "Copy to the clipboard failed\n",
  "クリップボードへのコピーに失敗しました\n", "클립보드 복사 실패\n", "Échec de la copie\n",
  "Kopieren fehlgeschlagen\n", "Error al copiar\n")
X(PINNED,
  "已贴到屏幕\n", "已貼到螢幕\n", "Pinned to the screen\n", "画面にピン留めしました\n", "화면에 고정됨\n",
  "Épinglé à l'écran\n", "Angeheftet\n", "Fijado en pantalla\n")
X(PIN_FAILED,
  "贴图失败\n", "貼圖失敗\n", "Pin failed\n", "ピン留めに失敗しました\n", "고정 실패\n",
  "Échec de l'épinglage\n", "Anheften fehlgeschlagen\n", "Error al fijar\n")
X(CAPTURING,
  "正在截图中\n", "正在截圖\n", "A capture is in progress\n", "キャプチャ中です\n", "캡처 중입니다\n",
  "Capture en cours\n", "Eine Aufnahme läuft bereits\n", "Captura en curso\n")
X(ERR_NEED_RECT,
  "--out / --clip / --pin 需要和 --rect 或 --full 一起用\n",
  "--out / --clip / --pin 需要和 --rect 或 --full 一起用\n",
  "--out / --clip / --pin need --rect or --full\n", "--out / --clip / --pin には --rect か --full が必要です\n",
  "--out / --clip / --pin은 --rect 또는 --full과 함께 써야 합니다\n",
  "--out / --clip / --pin exigent --rect ou --full\n", "--out / --clip / --pin brauchen --rect oder --full\n",
  "--out / --clip / --pin requieren --rect o --full\n")
X(CAP_CANNOT,
  "无法开始截图\n", "無法開始截圖\n", "Cannot start a capture\n", "キャプチャを開始できません\n",
  "캡처를 시작할 수 없습니다\n", "Impossible de lancer la capture\n", "Aufnahme lässt sich nicht starten\n",
  "No se puede iniciar la captura\n")
X(ERR_RECT,
  "--rect 的格式是 X,Y,宽,高，例如 --rect 0,0,800,600\n", "--rect 的格式是 X,Y,寬,高，例如 --rect 0,0,800,600\n",
  "--rect takes X,Y,width,height, e.g. --rect 0,0,800,600\n",
  "--rect の形式は X,Y,幅,高さ です（例：--rect 0,0,800,600）\n",
  "--rect 형식은 X,Y,너비,높이입니다 (예: --rect 0,0,800,600)\n",
  "--rect attend X,Y,largeur,hauteur, ex. --rect 0,0,800,600\n",
  "--rect erwartet X,Y,Breite,Höhe, z. B. --rect 0,0,800,600\n",
  "--rect usa X,Y,ancho,alto, p. ej. --rect 0,0,800,600\n")
X(ERR_READ_IMAGE,
  "无法读取图片：%s\n", "無法讀取圖片：%s\n", "Cannot read the image: %s\n", "画像を読み込めません：%s\n",
  "이미지를 읽을 수 없습니다: %s\n", "Image illisible : %s\n", "Bild nicht lesbar: %s\n",
  "No se puede leer la imagen: %s\n")
X(CLIP_EMPTY,
  "剪贴板里没有图片或文字\n", "剪貼簿裡沒有圖片或文字\n", "No image or text in the clipboard\n",
  "クリップボードに画像もテキストもありません\n", "클립보드에 이미지나 텍스트가 없습니다\n",
  "Ni image ni texte dans le presse-papiers\n", "Kein Bild oder Text in der Zwischenablage\n",
  "No hay imagen ni texto en el portapapeles\n")
X(CLIP_FAILED,
  "读取剪贴板失败\n", "讀取剪貼簿失敗\n", "Cannot read the clipboard\n", "クリップボードを読み取れません\n",
  "클립보드를 읽을 수 없습니다\n", "Presse-papiers illisible\n", "Zwischenablage nicht lesbar\n",
  "No se puede leer el portapapeles\n")
X(PIN_DONE,
  "已贴图 %d×%d\n", "已貼圖 %d×%d\n", "Pinned %d×%d\n", "%d×%d をピン留めしました\n", "%d×%d 고정됨\n",
  "Épinglé %d×%d\n", "%d×%d angeheftet\n", "Fijado %d×%d\n")
X(QUIT_DONE,
  "sniplite 已退出\n", "sniplite 已結束\n", "sniplite has quit\n", "sniplite を終了しました\n",
  "sniplite 종료됨\n", "sniplite est fermé\n", "sniplite beendet\n", "sniplite se ha cerrado\n")
X(ERR_SETTINGS,
  "无法打开首选项\n", "無法開啟偏好設定\n", "Cannot open Settings\n", "設定を開けません\n",
  "설정을 열 수 없습니다\n", "Impossible d'ouvrir les préférences\n", "Einstellungen lassen sich nicht öffnen\n",
  "No se pueden abrir los ajustes\n")
X(ERR_UNKNOWN_CMD,
  "不认识的命令：%s（用 sniplite help 查看用法）\n", "未知的指令：%s（用 sniplite help 查看用法）\n",
  "Unknown command: %s (see sniplite help)\n", "不明なコマンド：%s（使い方は sniplite help）\n",
  "알 수 없는 명령: %s (sniplite help 참고)\n", "Commande inconnue : %s (voir sniplite help)\n",
  "Unbekannter Befehl: %s (siehe sniplite help)\n", "Comando desconocido: %s (ver sniplite help)\n")

/* ---- tray menu ---- */
X(M_CAPTURE, "截屏", "截圖", "Capture", "キャプチャ", "캡처", "Capturer", "Aufnehmen", "Capturar")
X(M_PIN, "贴图", "貼圖", "Pin", "ピン留め", "고정", "Épingler", "Anheften", "Fijar")
X(M_SHOW_PINS,
  "显示所有贴图", "顯示所有貼圖", "Show all pins", "すべてのピンを表示", "고정 이미지 모두 표시",
  "Afficher les épingles", "Alle Pins einblenden", "Mostrar las fijadas")
X(M_HIDE_PINS,
  "隐藏所有贴图", "隱藏所有貼圖", "Hide all pins", "すべてのピンを隠す", "고정 이미지 모두 숨기기",
  "Masquer les épingles", "Alle Pins ausblenden", "Ocultar las fijadas")
X(M_CLOSE_PINS,
  "关闭所有贴图", "關閉所有貼圖", "Close all pins", "すべてのピンを閉じる", "고정 이미지 모두 닫기",
  "Fermer les épingles", "Alle Pins schließen", "Cerrar las fijadas")
X(M_SETTINGS, "首选项...", "偏好設定...", "Settings...", "設定...", "설정...", "Préférences...",
  "Einstellungen...", "Ajustes...")
X(M_HELP, "帮助", "說明", "Help", "ヘルプ", "도움말", "Aide", "Hilfe", "Ayuda")
X(M_UPDATE,
  "检查更新", "檢查更新", "Check for updates", "更新を確認", "업데이트 확인", "Rechercher des mises à jour",
  "Nach Updates suchen", "Buscar actualizaciones")
X(M_ABOUT,
  "关于 sniplite", "關於 sniplite", "About sniplite", "sniplite について", "sniplite 정보",
  "À propos de sniplite", "Über sniplite", "Acerca de sniplite")
X(M_EXIT, "退出", "結束", "Quit", "終了", "종료", "Quitter", "Beenden", "Salir")
X(TAGLINE,
  "轻量、快速的截图与贴图工具", "輕量、快速的截圖與貼圖工具", "A light, fast screenshot and pin tool",
  "軽くて速いスクリーンショット＆ピン留めツール", "가볍고 빠른 화면 캡처, 고정 도구",
  "Captures et épingles, légères et rapides", "Schlank und schnell: Screenshots und Pins",
  "Capturar y fijar, rápido y ligero")
X(HK_WARN_1,
  "有热键注册失败，可能已被其他程序（比如 Snipaste）占用：\n\n",
  "有快速鍵註冊失敗，可能已被其他程式（例如 Snipaste）佔用：\n\n",
  "Some hotkeys could not be registered. Another app (Snipaste, say) may be using them:\n\n",
  "登録できないホットキーがあります。他のアプリ（Snipaste など）が使用中かもしれません：\n\n",
  "일부 단축키를 등록하지 못했습니다. 다른 앱(예: Snipaste)이 사용 중일 수 있습니다:\n\n",
  "Raccourcis indisponibles, peut-être pris par une autre appli (Snipaste, par exemple) :\n\n",
  "Einige Tastenkürzel sind schon belegt, evtl. von einer anderen App (etwa Snipaste):\n\n",
  "No se pudieron registrar algunos atajos. Puede que otra app (como Snipaste) los use:\n\n")
X(HK_WARN_2,
  "\n可以在托盘图标的首选项里换一个。", "\n可以在系統匣圖示的偏好設定裡換一個。",
  "\nChange them in Settings, from the tray icon.", "\nトレイアイコンの設定から変更できます。",
  "\n트레이 아이콘의 설정에서 바꿀 수 있습니다.",
  "\nChangez-les dans les préférences, depuis l'icône de la zone de notification.",
  "\nÄndern lassen sie sich in den Einstellungen über das Tray-Symbol.",
  "\nCámbialos en los ajustes, desde el icono de la bandeja.")

/* ---- preferences (settings.c, sniplite.rc) ---- */
X(SETTINGS_TITLE,
  "sniplite 首选项", "sniplite 偏好設定", "sniplite Settings", "sniplite 設定", "sniplite 설정",
  "Préférences de sniplite", "sniplite-Einstellungen", "Ajustes de sniplite")
X(SHORTCUTS_TITLE,
  "sniplite 快捷键", "sniplite 快速鍵", "sniplite Shortcuts", "sniplite ショートカット", "sniplite 단축키",
  "Raccourcis de sniplite", "sniplite-Tastenkürzel", "Atajos de sniplite")
/* the five tabs, in the order of PG_* */
X(TAB_GENERAL, "常规", "一般", "General", "全般", "일반", "Général", "Allgemein", "General")
X(TAB_CAPTURE, "截屏", "截圖", "Capture", "キャプチャ", "캡처", "Capture", "Aufnahme", "Captura")
X(TAB_HOTKEYS, "控制", "快速鍵", "Hotkeys", "ホットキー", "단축키", "Raccourcis", "Tasten", "Atajos")
X(TAB_UPDATE, "更新", "更新", "Update", "更新", "업데이트", "Mise à jour", "Update", "Actualización")
X(TAB_ABOUT, "关于", "關於", "About", "情報", "정보", "À propos", "Info", "Acerca de")
X(G_AUTOSTART,
  "开机启动", "開機啟動", "Start with Windows", "Windows 起動時に実行", "Windows 시작 시 실행",
  "Lancer au démarrage", "Mit Windows starten", "Iniciar con Windows")
X(G_TRAY,
  "显示托盘图标", "顯示系統匣圖示", "Show the tray icon", "トレイアイコンを表示", "트레이 아이콘 표시",
  "Icône dans la zone de notification", "Tray-Symbol anzeigen", "Mostrar el icono de la bandeja")
X(G_LANG, "语言:", "語言:", "Language:", "言語:", "언어:", "Langue :", "Sprache:", "Idioma:")
X(G_LANG_AUTO, "自动（%s）", "自動（%s）", "Auto (%s)", "自動（%s）", "자동 (%s)", "Auto (%s)", "Automatisch (%s)",
  "Automático (%s)")
X(G_INI_GROUP,
  "配置文件存储位置", "設定檔位置", "Settings file", "設定ファイルの場所", "설정 파일 위치",
  "Fichier de réglages", "Einstellungsdatei", "Archivo de ajustes")
X(G_PATH, "路径:", "路徑:", "Path:", "パス:", "경로:", "Chemin :", "Pfad:", "Ruta:")
X(G_OPEN_DIR,
  "打开所在文件夹", "開啟資料夾", "Open folder", "フォルダーを開く", "폴더 열기", "Ouvrir le dossier",
  "Ordner öffnen", "Abrir carpeta")
X(G_OPEN_INI, "打开", "開啟", "Open", "開く", "열기", "Ouvrir", "Öffnen", "Abrir")
X(DEFAULTS, "恢复默认", "還原預設值", "Reset", "既定に戻す", "기본값 복원", "Réinitialiser", "Zurücksetzen",
  "Restablecer")
X(C_MODE, "截屏方式:", "截圖方式:", "Mode:", "方式:", "방식:", "Mode :", "Modus:", "Modo:")
X(C_DXGI, "极速（DXGI）", "極速（DXGI）", "Fast (DXGI)", "高速（DXGI）", "고속 (DXGI)", "Rapide (DXGI)",
  "Schnell (DXGI)", "Rápido (DXGI)")
X(C_GDI, "省内存（GDI）", "省記憶體（GDI）", "Low memory (GDI)", "省メモリ（GDI）", "메모리 절약 (GDI)",
  "Économe (GDI)", "Sparsam (GDI)", "Ligero (GDI)")
X(C_HINT,
  "极速：直接读取显卡画面，常驻约 50 MB 驱动内存。\n省内存：不占额外内存，多屏高分辨率时会慢几倍。",
  "極速：直接讀取顯示卡畫面，驅動程式約佔 50 MB 記憶體。\n省記憶體：不佔額外記憶體，多螢幕高解析度時會慢幾倍。",
  "Fast: reads the screen from the GPU and keeps about 50 MB of driver memory.\n"
  "Low memory: keeps none, but is several times slower on big screens.",
  "高速：GPU から画面を直接取得します。ドライバーが常時約 50 MB を使います。\n"
  "省メモリ：追加メモリは使いませんが、高解像度のマルチモニターでは数倍遅くなります。",
  "고속: GPU에서 화면을 직접 읽으며 드라이버가 약 50MB를 계속 씁니다.\n"
  "메모리 절약: 추가 메모리는 없지만 고해상도 다중 모니터에서는 몇 배 느립니다.",
  "Rapide : lit l'écran depuis le GPU, le pilote occupe environ 50 Mo.\n"
  "Économe : aucune mémoire en plus, mais plusieurs fois plus lent sur de grands écrans.",
  "Schnell: liest das Bild von der GPU und belegt dauerhaft etwa 50 MB Treiberspeicher.\n"
  "Sparsam: kein zusätzlicher Speicher, aber auf großen Bildschirmen mehrfach langsamer.",
  "Rápido: lee la pantalla desde la GPU y ocupa unos 50 MB de memoria del controlador.\n"
  "Ligero: sin memoria extra, pero varias veces más lento en pantallas grandes.")
X(H_CAPTURE, "截屏:", "截圖:", "Capture:", "キャプチャ:", "캡처:", "Capturer :", "Aufnehmen:", "Capturar:")
X(H_PIN, "贴图:", "貼圖:", "Pin:", "ピン留め:", "고정:", "Épingler :", "Anheften:", "Fijar:")
X(H_TOGGLE,
  "隐藏/显示所有贴图:", "隱藏/顯示所有貼圖:", "Hide/show pins:", "ピン表示切替:", "고정 표시/숨김:",
  "Masquer/afficher :", "Pins ein/aus:", "Ocultar/mostrar:")
X(H_HINT,
  "单击输入框后按下新的快捷键，Backspace 清除。", "點一下輸入框後按下新的快速鍵，Backspace 清除。",
  "Click a field, then press the new keys. Backspace clears it.",
  "入力欄をクリックして新しいキーを押します。Backspace で解除。",
  "입력란을 클릭하고 새 단축키를 누르세요. Backspace로 지웁니다.",
  "Cliquez sur un champ, puis tapez le raccourci. Retour arrière l'efface.",
  "Feld anklicken, dann die neuen Tasten drücken. Die Rücktaste löscht.",
  "Haz clic en un campo y pulsa las teclas. Retroceso lo borra.")
X(H_BUILTIN, "内置快捷键", "內建快速鍵", "Shortcuts", "ショートカット", "단축키 목록", "Aide-mémoire",
  "Tastenkürzel", "Ver atajos")
X(OK_BTN, "确定", "確定", "OK", "OK", "확인", "OK", "OK", "Aceptar")
X(U_VERSION,
  "当前版本：%s", "目前版本：%s", "Version %s", "現在のバージョン：%s", "현재 버전: %s", "Version %s",
  "Version %s", "Versión %s")
X(U_CHECK_BTN, "检查更新", "檢查更新", "Check now", "更新を確認", "지금 확인", "Rechercher", "Jetzt suchen",
  "Buscar")
X(U_INSTALL_BTN, "立即更新", "立即更新", "Update now", "今すぐ更新", "지금 업데이트", "Mettre à jour",
  "Aktualisieren", "Actualizar")
X(U_AUTO,
  "自动检查更新", "自動檢查更新", "Check for updates automatically", "自動で更新を確認", "업데이트 자동 확인",
  "Recherche automatique", "Automatisch nach Updates suchen", "Buscar automáticamente")
X(U_HINT,
  "只向 GitHub 查询最新版本号，不上传任何数据。", "只向 GitHub 查詢最新版本號，不上傳任何資料。",
  "Only asks GitHub for the latest version. Nothing is uploaded.",
  "GitHub に最新バージョンを問い合わせるだけで、データは送信しません。",
  "GitHub에서 최신 버전만 확인하며 데이터는 보내지 않습니다.",
  "Demande seulement la dernière version à GitHub. Rien n'est envoyé.",
  "Fragt bei GitHub nur die neueste Version ab. Es wird nichts hochgeladen.",
  "Solo consulta en GitHub la última versión. No se envía nada.")
X(A_LICENSE,
  "开源许可：MIT License", "開源授權：MIT License", "License: MIT", "ライセンス：MIT License",
  "라이선스: MIT", "Licence : MIT", "Lizenz: MIT", "Licencia: MIT")
X(HKF_PRESS, "按下快捷键", "按下快速鍵", "Press the keys", "キーを押してください", "단축키를 누르세요",
  "Tapez le raccourci", "Tasten drücken", "Pulsa las teclas")
/* the shortcut list: three groups, then what each row does and its keys */
X(SC_G_CAPTURE, "截图", "截圖", "Capture", "キャプチャ", "캡처", "Capture", "Aufnahme", "Captura")
X(SC_G_PIN, "贴图", "貼圖", "Pins", "ピン留め", "고정", "Épingles", "Pins", "Fijadas")
X(SC_G_TIPS, "小技巧", "小技巧", "Tips", "ヒント", "팁", "Astuces", "Tipps", "Trucos")
X(SC_START, "开始截图", "開始截圖", "Start a capture", "キャプチャ開始", "캡처 시작", "Lancer une capture",
  "Aufnahme starten", "Capturar")
X(SC_WINDOW,
  "选中整个窗口", "選取整個視窗", "Select a whole window", "ウィンドウ全体を選択", "창 전체 선택",
  "Sélectionner une fenêtre", "Ganzes Fenster wählen", "Seleccionar una ventana")
X(SC_COPY, "复制", "複製", "Copy", "コピー", "복사", "Copier", "Kopieren", "Copiar")
X(SC_SAVE, "保存", "儲存", "Save", "保存", "저장", "Enregistrer", "Speichern", "Guardar")
X(SC_PIN, "贴到屏幕", "貼到螢幕", "Pin to the screen", "画面にピン留め", "화면에 고정", "Épingler à l'écran",
  "Anheften", "Fijar en pantalla")
X(SC_CANCEL, "退出", "取消", "Cancel", "キャンセル", "취소", "Quitter", "Abbrechen", "Cancelar")
X(SC_UNDO, "撤销", "復原", "Undo", "元に戻す", "실행 취소", "Annuler", "Rückgängig", "Deshacer")
X(SC_PIN_CLIP,
  "把剪贴板贴出来", "把剪貼簿貼出來", "Pin the clipboard", "クリップボードをピン留め", "클립보드 내용 고정",
  "Épingler le presse-papiers", "Zwischenablage anheften", "Fijar el portapapeles")
X(SC_ZOOM, "放大缩小", "縮放", "Zoom", "拡大縮小", "확대/축소", "Zoom", "Zoomen", "Zoom")
X(SC_OPACITY, "调透明度", "調整透明度", "Opacity", "不透明度", "불투명도", "Opacité", "Deckkraft", "Opacidad")
X(SC_CLOSE, "关掉", "關閉", "Close", "閉じる", "닫기", "Fermer", "Schließen", "Cerrar")
X(SC_GROW,
  "选大一点 / 小一点", "選大一點 / 小一點", "Bigger / smaller area", "範囲を広く / 狭く", "영역 넓게 / 좁게",
  "Zone plus grande / petite", "Bereich größer / kleiner", "Zona mayor / menor")
X(SC_NUDGE, "挪一个像素", "移動一個像素", "Move by one pixel", "1 ピクセル移動", "1픽셀 이동",
  "Déplacer d'un pixel", "Um 1 Pixel verschieben", "Mover un píxel")
X(SC_COLOR, "取颜色", "取色", "Pick a color", "色を取得", "색상 추출", "Prélever une couleur", "Farbe kopieren",
  "Copiar el color")
X(K_CLICK, "单击", "點一下", "Click", "クリック", "클릭", "Clic", "Klick", "Clic")
X(K_ENTER_DBL,
  "Enter 或 双击", "Enter 或 點兩下", "Enter or double-click", "Enter またはダブルクリック", "Enter 또는 더블클릭",
  "Enter ou double-clic", "Enter oder Doppelklick", "Enter o doble clic")
X(K_WHEEL, "滚轮", "滾輪", "Wheel", "ホイール", "휠", "Molette", "Mausrad", "Rueda")
X(K_CTRL_WHEEL, "Ctrl+滚轮", "Ctrl+滾輪", "Ctrl+Wheel", "Ctrl+ホイール", "Ctrl+휠", "Ctrl+Molette", "Ctrl+Mausrad",
  "Ctrl+Rueda")
X(K_DBL_ESC,
  "双击 或 Esc", "點兩下 或 Esc", "Double-click or Esc", "ダブルクリックまたは Esc", "더블클릭 또는 Esc",
  "Double-clic ou Esc", "Doppelklick oder Esc", "Doble clic o Esc")
X(K_WHEEL_CAP,
  "截图时滚轮", "截圖時滾輪", "Wheel while capturing", "キャプチャ中にホイール", "캡처 중 휠",
  "Molette pendant la capture", "Mausrad bei der Aufnahme", "Rueda al capturar")
X(K_ARROWS, "方向键", "方向鍵", "Arrow keys", "矢印キー", "방향키", "Flèches", "Pfeiltasten", "Flechas")
X(K_C_CAP,
  "截图时按 C", "截圖時按 C", "C while capturing", "キャプチャ中に C", "캡처 중 C", "C pendant la capture",
  "C bei der Aufnahme", "C al capturar")
X(SC_UNSET, "（未设置）", "（未設定）", "(none)", "（未設定）", "(없음)", "(aucun)", "(nicht belegt)",
  "(sin asignar)")
/* the update page's status line */
X(U_CHECKING, "正在检查...", "正在檢查...", "Checking...", "確認中...", "확인 중...", "Recherche...",
  "Suche läuft...", "Buscando...")
X(U_CHECK_FAILED, "检查失败。", "檢查失敗。", "Check failed.", "確認に失敗しました。", "확인 실패.",
  "Échec de la recherche.", "Suche fehlgeschlagen.", "Error al buscar.")
X(U_NEWER_MANUAL,
  "有新版本：%s，请到 GitHub 下载。", "有新版本：%s，請到 GitHub 下載。", "New version %s on GitHub.",
  "新バージョン %s（GitHub で入手）", "새 버전 %s (GitHub에서 받기)", "Nouvelle version %s sur GitHub.",
  "Neue Version %s auf GitHub.", "Nueva versión %s en GitHub.")
X(U_NEWER,
  "有新版本：%s", "有新版本：%s", "New version: %s", "新バージョン：%s", "새 버전: %s",
  "Nouvelle version : %s", "Neue Version: %s", "Nueva versión: %s")
X(U_LATEST,
  "已是最新版本。", "已是最新版本。", "You're up to date.", "最新バージョンです。", "최신 버전입니다.",
  "Vous êtes à jour.", "Alles aktuell.", "Estás al día.")
X(U_NONE,
  "还没有发布的版本。", "還沒有發布的版本。", "No release yet.", "まだリリースがありません。",
  "아직 공개된 버전이 없습니다.", "Aucune version publiée.", "Noch keine Version veröffentlicht.",
  "Aún no hay versiones.")
X(U_NET_FAILED,
  "检查失败，请检查网络。", "檢查失敗，請確認網路。", "Check failed. Is the network up?",
  "確認に失敗。接続を確認してください。", "확인 실패. 네트워크를 확인하세요.", "Échec. Vérifiez le réseau.",
  "Fehlgeschlagen. Netzwerk prüfen.", "Error. Revisa la conexión.")
X(U_CONFIRM,
  "更新时 sniplite 会重新启动，屏幕上的贴图会关掉。\n要继续吗？",
  "更新時 sniplite 會重新啟動，螢幕上的貼圖會關掉。\n要繼續嗎？",
  "Updating restarts sniplite and closes the pins on screen.\nContinue?",
  "更新すると sniplite が再起動し、画面上のピンは閉じられます。\n続けますか？",
  "업데이트하면 sniplite가 다시 시작되고 화면의 고정 이미지가 닫힙니다.\n계속할까요?",
  "La mise à jour relance sniplite et ferme les épingles à l'écran.\nContinuer ?",
  "Das Update startet sniplite neu und schließt die Pins auf dem Bildschirm.\nFortfahren?",
  "Al actualizar, sniplite se reinicia y se cierran las imágenes fijadas.\n¿Continuar?")
X(U_DOWNLOADING, "正在下载...", "正在下載...", "Downloading...", "ダウンロード中...", "다운로드 중...",
  "Téléchargement...", "Download läuft...", "Descargando...")
X(U_DOWNLOAD_PCT,
  "正在下载... %d%%", "正在下載... %d%%", "Downloading... %d%%", "ダウンロード中... %d%%", "다운로드 중... %d%%",
  "Téléchargement... %d%%", "Download läuft... %d%%", "Descargando... %d%%")
X(U_DOWNLOAD_FAILED,
  "下载失败，请稍后再试。", "下載失敗，請稍後再試。", "Download failed. Try again later.",
  "ダウンロード失敗。後でお試しください。", "다운로드 실패. 나중에 다시 시도하세요.",
  "Échec. Réessayez plus tard.", "Fehlgeschlagen. Später erneut versuchen.", "Error. Inténtalo más tarde.")
X(U_INSTALLING, "正在安装...", "正在安裝...", "Installing...", "インストール中...", "설치 중...",
  "Installation...", "Installation läuft...", "Instalando...")
X(U_INSTALL_FAILED,
  "安装失败。", "安裝失敗。", "Install failed.", "インストールに失敗しました。", "설치 실패.",
  "Échec de l'installation.", "Installation fehlgeschlagen.", "Error al instalar.")
X(AUTOSTART_ADD_FAILED,
  "无法创建开机启动快捷方式。", "無法建立開機啟動捷徑。", "Cannot create the startup shortcut.",
  "スタートアップのショートカットを作成できません。", "시작 프로그램 바로 가기를 만들 수 없습니다.",
  "Impossible de créer le raccourci de démarrage.", "Die Autostart-Verknüpfung lässt sich nicht anlegen.",
  "No se puede crear el acceso directo de inicio.")
X(AUTOSTART_DEL_FAILED,
  "无法删除开机启动快捷方式。", "無法刪除開機啟動捷徑。", "Cannot remove the startup shortcut.",
  "スタートアップのショートカットを削除できません。", "시작 프로그램 바로 가기를 삭제할 수 없습니다.",
  "Impossible de supprimer le raccourci de démarrage.", "Die Autostart-Verknüpfung lässt sich nicht löschen.",
  "No se puede quitar el acceso directo de inicio.")

/* ---- uninstall (uninstall.c); the title is also the Start menu shortcut's name ---- */
X(UNINST_TITLE,
  "卸载 sniplite", "解除安裝 sniplite", "Uninstall sniplite", "sniplite のアンインストール", "sniplite 제거",
  "Désinstaller sniplite", "sniplite deinstallieren", "Desinstalar sniplite")
X(UNINST_CONFIRM,
  "要卸载 sniplite 吗？\n程序、设置和快捷方式都会删除。", "要解除安裝 sniplite 嗎？\n程式、設定和捷徑都會刪除。",
  "Uninstall sniplite?\nThe program, its settings and shortcuts will be removed.",
  "sniplite をアンインストールしますか？\nプログラム、設定、ショートカットが削除されます。",
  "sniplite를 제거할까요?\n프로그램, 설정, 바로 가기가 모두 삭제됩니다.",
  "Désinstaller sniplite ?\nLe programme, ses réglages et ses raccourcis seront supprimés.",
  "sniplite deinstallieren?\nProgramm, Einstellungen und Verknüpfungen werden entfernt.",
  "¿Desinstalar sniplite?\nSe eliminarán el programa, sus ajustes y sus accesos directos.")
X(UNINST_DONE,
  "sniplite 已卸载。", "sniplite 已解除安裝。", "sniplite was uninstalled.",
  "sniplite をアンインストールしました。", "sniplite가 제거되었습니다.", "sniplite a été désinstallé.",
  "sniplite wurde deinstalliert.", "sniplite se ha desinstalado.")

/* ---- the comments at the top of sniplite.ini (config.c) ---- */
X(INI_1,
  "; sniplite 设置（删除本文件即恢复默认）\r\n", "; sniplite 設定（刪除本檔案即還原預設值）\r\n",
  "; sniplite settings (delete this file to reset them)\r\n",
  "; sniplite の設定（このファイルを削除すると既定に戻ります）\r\n",
  "; sniplite 설정 (이 파일을 지우면 기본값으로 돌아갑니다)\r\n",
  "; Réglages de sniplite (supprimez ce fichier pour les réinitialiser)\r\n",
  "; sniplite-Einstellungen (Datei löschen setzt sie zurück)\r\n",
  "; Ajustes de sniplite (borra este archivo para restablecerlos)\r\n")
X(INI_2,
  "; 热键写法：F1、Ctrl+Alt+A、Shift+PrtSc，none 表示不用\r\n",
  "; 快速鍵寫法：F1、Ctrl+Alt+A、Shift+PrtSc，none 表示不用\r\n",
  "; hotkeys: F1, Ctrl+Alt+A, Shift+PrtSc, or none\r\n",
  "; ホットキーの書き方：F1、Ctrl+Alt+A、Shift+PrtSc、使わないときは none\r\n",
  "; 단축키 형식: F1, Ctrl+Alt+A, Shift+PrtSc, 사용하지 않으면 none\r\n",
  "; raccourcis : F1, Ctrl+Alt+A, Shift+PrtSc, ou none\r\n",
  "; Tastenkürzel: F1, Ctrl+Alt+A, Shift+PrtSc oder none\r\n",
  "; atajos: F1, Ctrl+Alt+A, Shift+PrtSc, o none\r\n")
X(INI_3,
  "; capture：dxgi 最快，gdi 最省内存\r\n", "; capture：dxgi 最快，gdi 最省記憶體\r\n",
  "; capture: dxgi is the fastest, gdi uses the least memory\r\n", "; capture：dxgi は最速、gdi は省メモリ\r\n",
  "; capture: dxgi가 가장 빠르고 gdi가 메모리를 가장 적게 씁니다\r\n",
  "; capture : dxgi est le plus rapide, gdi le plus économe en mémoire\r\n",
  "; capture: dxgi ist am schnellsten, gdi braucht am wenigsten Speicher\r\n",
  "; capture: dxgi es el más rápido, gdi el que menos memoria usa\r\n")

/* ---- the capture overlay (ov_*.S) ---- */
/* tool bar tooltips: the nine tools in the order of the buttons */
X(TIP_TOOL1, "矩形  Ctrl+1", "矩形  Ctrl+1", "Rectangle  Ctrl+1", "四角形  Ctrl+1", "사각형  Ctrl+1",
  "Rectangle  Ctrl+1", "Rechteck  Ctrl+1", "Rectángulo  Ctrl+1")
X(TIP_TOOL2, "椭圆  Ctrl+2", "橢圓  Ctrl+2", "Ellipse  Ctrl+2", "楕円  Ctrl+2", "타원  Ctrl+2", "Ellipse  Ctrl+2",
  "Ellipse  Ctrl+2", "Elipse  Ctrl+2")
X(TIP_TOOL3, "直线  Ctrl+3", "直線  Ctrl+3", "Line  Ctrl+3", "直線  Ctrl+3", "직선  Ctrl+3", "Ligne  Ctrl+3",
  "Linie  Ctrl+3", "Línea  Ctrl+3")
X(TIP_TOOL4, "箭头  Ctrl+4", "箭頭  Ctrl+4", "Arrow  Ctrl+4", "矢印  Ctrl+4", "화살표  Ctrl+4", "Flèche  Ctrl+4",
  "Pfeil  Ctrl+4", "Flecha  Ctrl+4")
X(TIP_TOOL5, "画笔  Ctrl+5", "畫筆  Ctrl+5", "Pen  Ctrl+5", "ペン  Ctrl+5", "펜  Ctrl+5", "Crayon  Ctrl+5",
  "Stift  Ctrl+5", "Lápiz  Ctrl+5")
X(TIP_TOOL6, "记号笔  Ctrl+6", "螢光筆  Ctrl+6", "Marker  Ctrl+6", "マーカー  Ctrl+6", "형광펜  Ctrl+6",
  "Surligneur  Ctrl+6", "Textmarker  Ctrl+6", "Resaltador  Ctrl+6")
X(TIP_TOOL7, "马赛克  Ctrl+7", "馬賽克  Ctrl+7", "Mosaic  Ctrl+7", "モザイク  Ctrl+7", "모자이크  Ctrl+7",
  "Mosaïque  Ctrl+7", "Verpixeln  Ctrl+7", "Mosaico  Ctrl+7")
X(TIP_TOOL8, "文字  Ctrl+8", "文字  Ctrl+8", "Text  Ctrl+8", "テキスト  Ctrl+8", "텍스트  Ctrl+8", "Texte  Ctrl+8",
  "Text  Ctrl+8", "Texto  Ctrl+8")
X(TIP_TOOL9, "序号  Ctrl+9", "序號  Ctrl+9", "Number  Ctrl+9", "番号  Ctrl+9", "번호  Ctrl+9", "Numéro  Ctrl+9",
  "Nummer  Ctrl+9", "Número  Ctrl+9")
X(TIP_UNDO, "撤销  Ctrl+Z", "復原  Ctrl+Z", "Undo  Ctrl+Z", "元に戻す  Ctrl+Z", "실행 취소  Ctrl+Z",
  "Annuler  Ctrl+Z", "Rückgängig  Ctrl+Z", "Deshacer  Ctrl+Z")
X(TIP_REDO, "重做  Ctrl+Y", "重做  Ctrl+Y", "Redo  Ctrl+Y", "やり直し  Ctrl+Y", "다시 실행  Ctrl+Y",
  "Rétablir  Ctrl+Y", "Wiederholen  Ctrl+Y", "Rehacer  Ctrl+Y")
X(TIP_PIN,
  "贴到屏幕  Ctrl+T / F3", "貼到螢幕  Ctrl+T / F3", "Pin to the screen  Ctrl+T / F3", "画面にピン留め  Ctrl+T / F3",
  "화면에 고정  Ctrl+T / F3", "Épingler à l'écran  Ctrl+T / F3", "Anheften  Ctrl+T / F3",
  "Fijar en pantalla  Ctrl+T / F3")
X(TIP_SAVE, "保存  Ctrl+S", "儲存  Ctrl+S", "Save  Ctrl+S", "保存  Ctrl+S", "저장  Ctrl+S", "Enregistrer  Ctrl+S",
  "Speichern  Ctrl+S", "Guardar  Ctrl+S")
X(TIP_QUIT, "退出  Esc", "取消  Esc", "Cancel  Esc", "キャンセル  Esc", "취소  Esc", "Quitter  Esc", "Abbrechen  Esc",
  "Cancelar  Esc")
X(TIP_COPY,
  "复制  Enter / Ctrl+C", "複製  Enter / Ctrl+C", "Copy  Enter / Ctrl+C", "コピー  Enter / Ctrl+C",
  "복사  Enter / Ctrl+C", "Copier  Enter / Ctrl+C", "Kopieren  Enter / Ctrl+C", "Copiar  Enter / Ctrl+C")
/* the three sizes */
X(TIP_SIZE0, "细  (滚轮调节)", "細  (滾輪調整)", "Thin  (wheel to change)", "細い  (ホイールで調整)",
  "가늘게  (휠로 조절)", "Fin  (molette pour changer)", "Dünn  (Mausrad zum Ändern)", "Fino  (rueda para cambiar)")
X(TIP_SIZE1, "中  (滚轮调节)", "中  (滾輪調整)", "Medium  (wheel to change)", "普通  (ホイールで調整)",
  "보통  (휠로 조절)", "Moyen  (molette pour changer)", "Mittel  (Mausrad zum Ändern)",
  "Medio  (rueda para cambiar)")
X(TIP_SIZE2, "粗  (滚轮调节)", "粗  (滾輪調整)", "Thick  (wheel to change)", "太い  (ホイールで調整)",
  "굵게  (휠로 조절)", "Épais  (molette pour changer)", "Dick  (Mausrad zum Ändern)",
  "Grueso  (rueda para cambiar)")
/* the eight colors in the order of the swatches */
X(COLOR_RED, "红色", "紅色", "Red", "赤", "빨강", "Rouge", "Rot", "Rojo")
X(COLOR_ORANGE, "橙色", "橙色", "Orange", "オレンジ", "주황", "Orange", "Orange", "Naranja")
X(COLOR_YELLOW, "黄色", "黃色", "Yellow", "黄", "노랑", "Jaune", "Gelb", "Amarillo")
X(COLOR_GREEN, "绿色", "綠色", "Green", "緑", "초록", "Vert", "Grün", "Verde")
X(COLOR_BLUE, "蓝色", "藍色", "Blue", "青", "파랑", "Bleu", "Blau", "Azul")
X(COLOR_PURPLE, "紫色", "紫色", "Purple", "紫", "보라", "Violet", "Violett", "Morado")
X(COLOR_BLACK, "黑色", "黑色", "Black", "黒", "검정", "Noir", "Schwarz", "Negro")
X(COLOR_WHITE, "白色", "白色", "White", "白", "흰색", "Blanc", "Weiß", "Blanco")
X(OV_SAVE_FAILED,
  "保存失败，请检查路径和权限。", "儲存失敗，請檢查路徑和權限。", "Save failed. Check the path and permissions.",
  "保存に失敗しました。パスと権限を確認してください。", "저장 실패. 경로와 권한을 확인하세요.",
  "Échec de l'enregistrement. Vérifiez le chemin et les droits.",
  "Speichern fehlgeschlagen. Pfad und Rechte prüfen.", "Error al guardar. Revisa la ruta y los permisos.")

/* ---- pins (pin.S) ---- */
X(PIN_OPACITY, "不透明度 %d%%", "不透明度 %d%%", "Opacity %d%%", "不透明度 %d%%", "불투명도 %d%%", "Opacité %d%%",
  "Deckkraft %d%%", "Opacidad %d%%")
X(PIN_COPIED, "已复制", "已複製", "Copied", "コピーしました", "복사됨", "Copié", "Kopiert", "Copiado")
X(PIN_SAVED, "已保存", "已儲存", "Saved", "保存しました", "저장됨", "Enregistré", "Gespeichert", "Guardado")
X(PIN_SAVE_FAILED, "保存失败", "儲存失敗", "Save failed", "保存できません", "저장 실패", "Échec", "Fehlgeschlagen",
  "Error al guardar")
X(PM_COPY, "复制\tCtrl+C", "複製\tCtrl+C", "Copy\tCtrl+C", "コピー\tCtrl+C", "복사\tCtrl+C", "Copier\tCtrl+C",
  "Kopieren\tCtrl+C", "Copiar\tCtrl+C")
X(PM_SAVE,
  "另存为...\tCtrl+S", "另存新檔...\tCtrl+S", "Save as...\tCtrl+S", "名前を付けて保存...\tCtrl+S",
  "다른 이름으로 저장...\tCtrl+S", "Enregistrer sous...\tCtrl+S", "Speichern unter...\tCtrl+S",
  "Guardar como...\tCtrl+S")
X(PM_RESET, "恢复原始大小", "原始大小", "Original size", "元のサイズに戻す", "원래 크기로", "Taille d'origine",
  "Originalgröße", "Tamaño original")
X(PM_CLOSE, "关闭\tEsc", "關閉\tEsc", "Close\tEsc", "閉じる\tEsc", "닫기\tEsc", "Fermer\tEsc", "Schließen\tEsc",
  "Cerrar\tEsc")

/* ---- the save dialog (image.S); | stands for the separator between filter parts ---- */
X(SAVE_FILTER,
  "PNG 图片 (*.png)|*.png|JPEG 图片 (*.jpg)|*.jpg;*.jpeg|BMP 图片 (*.bmp)|*.bmp|",
  "PNG 圖片 (*.png)|*.png|JPEG 圖片 (*.jpg)|*.jpg;*.jpeg|BMP 圖片 (*.bmp)|*.bmp|",
  "PNG image (*.png)|*.png|JPEG image (*.jpg)|*.jpg;*.jpeg|BMP image (*.bmp)|*.bmp|",
  "PNG 画像 (*.png)|*.png|JPEG 画像 (*.jpg)|*.jpg;*.jpeg|BMP 画像 (*.bmp)|*.bmp|",
  "PNG 이미지 (*.png)|*.png|JPEG 이미지 (*.jpg)|*.jpg;*.jpeg|BMP 이미지 (*.bmp)|*.bmp|",
  "Image PNG (*.png)|*.png|Image JPEG (*.jpg)|*.jpg;*.jpeg|Image BMP (*.bmp)|*.bmp|",
  "PNG-Bild (*.png)|*.png|JPEG-Bild (*.jpg)|*.jpg;*.jpeg|BMP-Bild (*.bmp)|*.bmp|",
  "Imagen PNG (*.png)|*.png|Imagen JPEG (*.jpg)|*.jpg;*.jpeg|Imagen BMP (*.bmp)|*.bmp|")
X(SAVE_TITLE, "保存截图", "儲存截圖", "Save the capture", "キャプチャを保存", "캡처 저장",
  "Enregistrer la capture", "Aufnahme speichern", "Guardar captura")

#endif
