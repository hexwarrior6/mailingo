XCODEGEN := .tools/xcodegen/bin/xcodegen
DERIVED  := .build/DerivedData
CONFIG   := Debug
APP      := $(DERIVED)/Build/Products/$(CONFIG)/Mailingo.app
APPEX    := $(APP)/Contents/PlugIns/MailingoMailExtension.appex
LOGDIR   := $(HOME)/Library/Containers/com.zhuyuhao.Mailingo.MailExtension/Data/Library/Logs/Mailingo
LEGACY   := $(HOME)/Library/Logs/Mailingo
LOG      := $(LOGDIR)/probe.log

.PHONY: help gen build run register status log stream diagnose clean reset-log install-app verify-appex refresh-plugins

help:
	@echo "make gen        生成 Mailingo.xcodeproj（XcodeGen）"
	@echo "make build      编译（含 appex 嵌入）"
	@echo "make run        编译并启动容器 App（探针看板）"
	@echo "make register   向 pluginkit 注册 appex，并列出 Mail 扩展"
	@echo "make status     打印 S0 判定摘要"
	@echo "make log        实时跟随探针日志"
	@echo "make stream     用 os_log 实时跟随（另一个视角）"
	@echo "make diagnose   查 appex 到底有没有被 Mail 拉起（在自己的终端跑）"
	@echo "make install-app 把 App 拷到 /Applications（Mail 更可靠地发现扩展）"
	@echo "make refresh-plugins 重新注册扩展并列出 Mail 扩展"
	@echo "make reset-log  清空探针日志与落盘的 MIME"

gen:
	$(XCODEGEN) generate --spec project.yml --project .

build: gen
	xcodebuild -project Mailingo.xcodeproj -scheme Mailingo -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) build

run: build
	open "$(APP)"

register: build
	@echo "== 注册 appex =="
	-pluginkit -a "$(APPEX)"
	@echo "== 已注册的 Mail 扩展 =="
	-pluginkit -m -v -p com.apple.email.extension

status:
	@bash Scripts/s0-status.sh

log:
	@mkdir -p "$(LOGDIR)"
	@touch "$(LOG)"
	@echo "跟随 $(LOG)   (Ctrl-C 退出)"
	@tail -n 200 -f "$(LOG)"

stream:
	log stream --style compact --predicate 'subsystem == "com.zhuyuhao.Mailingo"'

# 地面真相：不依赖文件写入，直接问系统「appex 到底有没有被 Mail 拉起」。
# 在**你自己的终端**里跑（本仓库的 agent 沙盒里 log show / pluginkit 都会被拒）。
diagnose:
	@echo "=========== 1. 我们的 os_log（appex 与容器 App 都打这里）==========="
	-log show --last 2h --style compact --predicate 'subsystem == "com.zhuyuhao.Mailingo"' 2>&1 | tail -40
	@echo ""
	@echo "=========== 2. appex 进程是否被拉起过 ==========="
	-log show --last 2h --style compact --predicate 'process == "MailingoMailExtension"' 2>&1 | tail -20
	@echo ""
	@echo "=========== 3. 系统关于 MailingoMailExtension 的记录 ==========="
	-log show --last 2h --style compact --predicate 'eventMessage CONTAINS "MailingoMailExtension"' 2>&1 | tail -30
	@echo ""
	@echo "=========== 4. Mail 扩展注册情况 ==========="
	-pluginkit -m -p com.apple.email.extension -v
	@echo ""
	@echo "=========== 5. 容器目录内容 ==========="
	-ls -la "$(LOGDIR)"

reset-log:
	rm -f "$(LOG)" "$(LOGDIR)/last-message.eml"
	rm -f "$(LEGACY)/probe.log" "$(LEGACY)/last-message.eml"
	@echo "已清空 $(LOGDIR)"

# 强制让 LaunchServices/pkd 重新扫描扩展。改完 project.yml 或重装后建议跑一次。
refresh-plugins:
	-/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "/Applications/Mailingo.app"
	-pluginkit -a "$(APPEX)"
	@echo "== 已注册的 Mail 扩展 =="
	-pluginkit -m -p com.apple.email.extension -v

install-app: build verify-appex
	@echo "== 拷贝到 /Applications（会覆盖同名 App）=="
	rm -rf "/Applications/Mailingo.app"
	ditto "$(APP)" "/Applications/Mailingo.app"
	@echo "== 重新注册（必须在拷贝之后）=="
	$(MAKE) --no-print-directory refresh-plugins
	@echo ""
	@echo "下一步：完全退出 Mail（⌘Q）再重开 → Mail → 设置 → 扩展 → 勾选 Mailingo"

verify-appex:
	@bash Scripts/verify-appex.sh "$(APP)"

clean:
	rm -rf .build Mailingo.xcodeproj Support
