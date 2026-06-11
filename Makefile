APP = ClaudeUsageBar
DEST = /Applications/$(APP).app

build:
	swift build -c release

install: build
	rm -rf $(DEST)
	mkdir -p $(DEST)/Contents/MacOS
	cp .build/release/$(APP) $(DEST)/Contents/MacOS/$(APP)
	cp Info.plist $(DEST)/Contents/Info.plist
	codesign --force -s - $(DEST)
	open $(DEST)

uninstall:
	osascript -e 'quit app "$(APP)"' 2>/dev/null || true
	rm -rf $(DEST)

.PHONY: build install uninstall
