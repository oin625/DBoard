# D板 CLI 上线事项完成勾选

已增加按事项编号完成／取消完成的 CLI 接口，并更新本机已安装入口；源码全套 184 项测试和安装后 17 项清单回归均通过。

`report --release-done L001` 设置完成，`--release-undone L001` 取消完成；重复参数支持批量操作。直接更新原清单的 done 字段，保留名称、明细、分类、证据和 updated_by。相同状态不会切换，原 event-id 重试不重复写入；状态冲突、目标不存在和过期 revision 拒绝整次写入。原内容修改／删除保护、CR只读限制和已完成需求保护继续生效。

CLI 帮助、Tools/README.md、执行反馈 Skill、业务反馈与排查操作规则已同步：用户明确要求，或在授权范围内执行事项并核验成功后，回写对应完成状态，不用修改名称代替勾选。部署制品与发布服务分别按原事项核验。

本机 /Users/zz/.local/bin/dboard-ai 对应的应用 CLI 和三份规则文件已增量更新，与仓库内容一致；使用既有签名证书重新签名，并通过 codesign --verify --deep --strict。未重装应用或重启现有进程。

验证：python3 -m unittest discover -s CLITests -v：184 项通过；通过已安装 /Users/zz/.local/bin/dboard-ai 执行同一清单测试：17 项通过。帮助及 guide 已返回两个新参数。测试仅使用临时缓存，未改动真实 D016 清单；本次 CLI 功能未绑定为 D016 业务交付。
