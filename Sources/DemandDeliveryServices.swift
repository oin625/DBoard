import Foundation

extension DemandDeliveryServices {
    static var live: Self {
        Self(generate: { plan in
            plan.document()
        }, validate: { link in
            let response = try DemandDeliveryRemote.request("detail/\(link.id)")
            guard let detail = response["data"] as? [String: Any],
                  detail["id"] as? Int == link.id, detail["reqNo"] as? String == link.no else {
                throw DemandDeliveryError.message("需求流编号与关联记录不一致，已停止提交，请重新关联。")
            }
            _ = try DemandDeliveryRemote.folderInfo()
        }, findDocument: { title in
            let info = try DemandDeliveryRemote.folderInfo()
            var cursor: String?
            var seen = Set<String>()
            var matches: [String] = []
            repeat {
                var args = ["drive", "list", "--workspace", info.workspace, "--folder", DemandDeliveryPlan.folder, "--limit", "50"]
                if let cursor { args += ["--cursor", cursor] }
                let page = try DemandDeliveryRemote.dws(args)
                guard let nodes = page["nodes"] as? [[String: Any]], let more = page["hasMore"] as? Bool else {
                    throw DemandDeliveryError.message("无法核验技术交付物目录，未创建文档。")
                }
                for node in nodes where node["name"] as? String == title {
                    matches.append(try DemandDeliveryRemote.documentURL(node))
                }
                cursor = more ? page["nextPageToken"] as? String : nil
                if more {
                    guard let cursor, !cursor.isEmpty, seen.insert(cursor).inserted else {
                        throw DemandDeliveryError.message("技术交付物目录分页异常，未创建文档；请重试。")
                    }
                }
            } while cursor != nil
            guard matches.count <= 1 else { throw DemandDeliveryError.message("目录中有多份同名技术说明，请先核对，避免关联错误。") }
            return matches.first
        }, createDocument: { title, markdown in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardDelivery-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file = temporary.appendingPathComponent("technical.md")
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try markdown.write(to: file, atomically: true, encoding: .utf8)
            } catch { throw DemandDeliveryDocumentRejected(message: "本地技术说明暂存失败，未创建文档；请重试。") }
            let result = try DemandDeliveryRemote.dws(["doc", "create", "--name", title,
                "--content-file", file.path, "--folder", DemandDeliveryPlan.folder])
            return try DemandDeliveryRemote.documentURL(result)
        }, verifyDocument: { url, expected in
            let document = try DemandDeliveryRemote.dws(["doc", "read", "--node", url])
            guard let markdown = document["markdown"] as? String else {
                throw DemandDeliveryError.message("技术说明已创建，但正文暂时无法核验，尚未提交交付物；可打开文档查看。")
            }
            guard DemandDeliveryDocumentVerification.matches(actual: markdown, expected: expected) else {
                throw DemandDeliveryError.message("技术文档正文与本次说明不一致，已保留链接，尚未提交交付物；请打开核对。")
            }
        }, listDeliverables: { id in
            let data = try DemandDeliveryRemote.requestData("deliverable/list/\(id)")
            return try DevelopmentDeliverables.decode(data)
        }, submit: { plan, url in
            let body: [String: Any] = ["reqId": plan.link.id, "deliverableType": 3,
                "deliverableContent": url, "attachmentIds": [], "deliverableAiCreate": 0,
                "deliverableDevProject": plan.projects.map(\.declaration).joined(separator: ",")]
            _ = try DemandDeliveryRemote.requestData("deliverable/uploadWithAttachments", body: body)
        }, readDocument: { url in
            let value = try DemandDeliveryRemote.dws(["doc", "read", "--node", url])
            guard let markdown = value["markdown"] as? String else {
                throw DemandDeliveryError.message("技术方案正文暂时无法读取，未更新远端文档。")
            }
            return markdown
        }, updateDocument: { url, markdown in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardPlan-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("plan.md")
            try markdown.write(to: file, atomically: true, encoding: .utf8)
            _ = try DemandDeliveryRemote.dws(["doc", "update", "--node", url, "--content-file", file.path,
                "--mode", "overwrite", "--yes"])
        }, renameDocument: { url, previous, title in
            let current = try DemandDeliveryRemote.dws(["doc", "read", "--node", url])
            if current["title"] as? String == title { return }
            guard current["title"] as? String == previous else {
                throw DemandDeliveryError.message("远端方案标题已被修改，请核对后再提交。")
            }
            _ = try DemandDeliveryRemote.dws(["drive", "rename", "--node", url, "--name", title])
        })
    }
}

enum DemandDeliveryRemote {
    static func requestData(_ path: String, body: [String: Any]? = nil) throws -> Data {
        guard let cookie = BizMapViewModel.readStatusCookie() else {
            throw DemandDeliverySubmissionRejected(message: "需求流尚未登录，请先刷新登录信息。")
        }
        var request = URLRequest(url: URL(string: "https://ai.tmallyc.com/prd/api/requirement/" + path)!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try URLSession.shared.syncData(for: request)
        guard let http = response as? HTTPURLResponse else { throw DemandDeliveryError.message("需求流未返回有效响应。") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DemandDeliverySubmissionRejected(message: "需求流登录已过期，请更新登录信息后重试。")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Server errors can occur after committing a write; preserve the pending checkpoint.
            if body != nil && http.statusCode >= 500 {
                throw DemandDeliveryError.message("需求流返回异常，提交结果待核验（HTTP \(http.statusCode)）。")
            }
            throw DemandDeliverySubmissionRejected(message: "需求流请求失败（HTTP \(http.statusCode)），请重试。")
        }
        guard BusinessResponse.succeeded(data) else {
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if value?["success"] as? Bool == false {
                throw DemandDeliverySubmissionRejected(message: "需求流操作失败：" + (value?["message"] as? String ?? "请核对项目分支与需求权限。"))
            }
            throw DemandDeliveryError.message("需求流返回无法核验，提交结果待确认。")
        }
        return data
    }

    static func request(_ path: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: requestData(path)) as? [String: Any] else {
            throw DemandDeliveryError.message("需求流返回格式异常。")
        }
        return object
    }

    static func dws(_ arguments: [String]) throws -> [String: Any] {
        let result = ProcessRunner.run(NSHomeDirectory() + "/.qoderwork/bin/dws",
            arguments: arguments + ["--format", "json", "--timeout", "20"],
            environment: ProcessInfo.processInfo.environment, timeout: 35)
        guard result.succeeded, BusinessResponse.succeeded(result.stdout),
              let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            let errorData = result.stderr.isEmpty ? result.stdout : result.stderr
            let failure = (try? JSONSerialization.jsonObject(with: errorData)) as? [String: Any]
            let detail = failure?["error"] as? [String: Any]
            let category = detail?["category"] as? String ?? ""
            if arguments.prefix(2) == ["doc", "create"], !result.timedOut, result.outputComplete,
               ["auth", "validation"].contains(category) {
                throw DemandDeliveryDocumentRejected(message: "钉钉未创建文档，请确认登录与目录权限后重试。")
            }
            throw DemandDeliveryError.message("钉钉文档操作失败，请确认 dws 登录与目录权限后重试；已有文档会保留。")
        }
        return object
    }

    static func folderInfo() throws -> (workspace: String, node: String) {
        let info = try dws(["doc", "info", "--node", DemandDeliveryPlan.folder])
        guard info["nodeType"] as? String == "folder",
              let workspace = info["workspaceId"] as? String, !workspace.isEmpty,
              let node = info["nodeId"] as? String,
              node == URL(string: DemandDeliveryPlan.folder)?.lastPathComponent else {
            throw DemandDeliveryError.message("技术交付物目标目录无法确认，未创建文档。")
        }
        return (workspace, node)
    }

    static func documentURL(_ object: [String: Any]) throws -> String {
        if let text = object["docUrl"] as? String, let url = URL(string: text),
           url.host == "alidocs.dingtalk.com", url.path.hasPrefix("/i/nodes/") {
            // Canonicalize links so query parameters do not break retry matching.
            return "https://alidocs.dingtalk.com" + url.path
        }
        guard let node = object["nodeId"] as? String ?? object["dentryUuid"] as? String,
              node.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw DemandDeliveryError.message("钉钉没有返回可用技术文档链接，未提交交付物。")
        }
        return "https://alidocs.dingtalk.com/i/nodes/" + node
    }
}
