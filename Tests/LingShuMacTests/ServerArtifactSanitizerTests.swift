import XCTest
@testable import LingShuMac

final class ServerArtifactSanitizerTests: XCTestCase {
    func testStripsMinioDownloadLinkAndServerPaths() {
        let reply = """
        我已经生成了介绍协作网络的 PPT。

        **文件信息：**
        - 文件路径：`/opt/hermes-exports/介绍协作网络 Agent.pptx`
        - 文件大小：33.8 KB

        ## 文件下载
        - [介绍协作网络 Agent.pptx](https://model-gateway.datanet.bj.cn/v1/files/download?source=http%3A%2F%2Fminio.datanet.bj.cn%2Fai-temp-film%2F...&X-Amz-Signature=abc)

        你可以直接打开查看。
        """
        let cleaned = LingShuExecutionCoordinator.sanitizeServerArtifactReferences(reply)

        XCTAssertFalse(cleaned.contains("minio"))
        XCTAssertFalse(cleaned.contains("/v1/files/download"))
        XCTAssertFalse(cleaned.contains("hermes-exports"))
        XCTAssertFalse(cleaned.contains("X-Amz-Signature"))
        XCTAssertFalse(cleaned.contains("文件下载"))
        XCTAssertTrue(cleaned.contains("我已经生成了介绍协作网络的 PPT。"))
        XCTAssertTrue(cleaned.contains("你可以直接打开查看。"))
    }

    func testLeavesCleanReplyUntouched() {
        let reply = "这是一段正常的回复，没有任何服务端路径或下载链接。"
        XCTAssertEqual(LingShuExecutionCoordinator.sanitizeServerArtifactReferences(reply), reply)
    }
}
