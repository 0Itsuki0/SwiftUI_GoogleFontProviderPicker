
import SwiftUI
import WebKit
import ZIPFoundation

struct GoogleFontProviderDemo: View {
    @State private var googleFontProvider = GoogleFontProvider()
    @State private var usingFontFamily: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                "- Download / Register google fonts upon request"
                            )
                            Text("- No pre-download / bundled ttf files.")
                        }

                        if let error = googleFontProvider.error {
                            Text("Error: \(error.localizedDescription)")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.horizontal, 0)
                }

                Section("TEST VIEW") {
                    let size: CGFloat = 16.0
                    let font: Font =
                        if let usingFontFamily {
                            .custom(usingFontFamily, size: size)
                        } else {
                            .system(size: size)
                        }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Choose a font below and see it applied!")
                        if let usingFontFamily {
                            Text("Current Font: \(usingFontFamily)")
                        }
                    }
                    .font(font)

                }

                Section("Google Font Picker") {
                    ForEach(
                        self.googleFontProvider.availableFontFamilies,
                        id: \.self
                    ) { font in
                        GoogleFontCell(
                            usingFontFamily: self.$usingFontFamily,
                            font: font
                        )
                    }
                }
            }
            .disabled(self.googleFontProvider.downloading)
            .navigationTitle("Google Font Picker")
            .overlay {
                if !googleFontProvider.initialized {
                    ProgressView()
                }
            }
            .environment(self.googleFontProvider)
        }
    }
}

private struct GoogleFontCell: View {
    @Environment(GoogleFontProvider.self) var googleFontProvider

    @Binding var usingFontFamily: String?
    var font: String

    @State private var downloading: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GoogleFontPreviewView(fontFamily: font)
                Button(
                    action: {
                        Task {
                            self.downloading = true
                            defer {
                                self.downloading = false
                            }
                            do {
                                try await googleFontProvider
                                    .downloadAndRegisterFontFamily(font)
                                self.usingFontFamily = font
                            } catch (let error) {
                                googleFontProvider.error = error
                            }
                        }
                    },
                    label: {
                        if downloading {
                            ProgressView()
                        } else {
                            Text("Use font")
                        }
                    }
                )
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 4)

            Divider()
        }
        .frame(height: 48)
        .listRowSeparator(.hidden)
        .disabled(downloading)
    }
}

private struct GoogleFontPreviewView: View {
    var fontFamily: String
    var fontSize: Int = 16

    @State private var webPage = WebPage()

    var body: some View {
        WebView(webPage)
            .scrollDisabled(true)
            .overlay {
                if webPage.isLoading {
                    HStack(spacing: 16) {
                        Text(self.fontFamily)
                            .font(.system(size: CGFloat(self.fontSize)))
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear {
                initWebpage()
            }
    }

    func initWebpage() {
        webPage.load(
            html: """
                    <!DOCTYPE html>
                    <html>
                    <head>
                        <meta name='viewport' content='width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no'>
                        <link href="https://fonts.googleapis.com/css2?family=\(self.fontFamily)" rel="stylesheet">
                    </head>
                    <body>
                        <div style="font-family: '\(self.fontFamily)'; font-size: \(self.fontSize)px; padding:0px; margin: 0px;display: flex; align-items: center; ">
                          \(self.fontFamily)
                        </div>
                    </body>
                    </html>
                """
        )
    }
}

@Observable
class GoogleFontProvider: NSObject {
    // URL for get a list of fonts Google Fonts provides
    private let metadataURL = "https://fonts.google.com/metadata/fonts"
    // URL for downloading a font, for example, for Fredoka, https://fonts.google.com/download?family=Fredoka
    // NOTE: Direct GET request will not work as the font zip file is generated in the background after receiving the request
    private let downloadBaseURL = "https://fonts.google.com/download"

    private let destinationFolder = URL.temporaryDirectory
        .appendingPathComponent(
            "tempDownload"
        )

    private let webview = WKWebView()
    private(set) var availableFontFamilies: [String] = []
    private var registeredFontFamily: Set<String> = []
    private(set) var downloading: Bool = false
    private(set) var initialized: Bool = false
    var error: Error? {
        didSet {
            if let error {
                print("error: ", error)
            }
        }
    }
    private var lastDownloadURL: URL?

    override init() {
        super.init()
        webview.navigationDelegate = self
        Task {
            do {
                try await self.getMetadata()
            } catch (let error) {
                self.error = error
            }
            self.initialized = true
        }
    }

    private func getMetadata() async throws {
        guard let url = URL(string: metadataURL) else {
            return
        }
        let request = URLRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.isSuccess == false {
            throw FontError.networkError(
                code: (response as? HTTPURLResponse)?.statusCode
            )
        }
        let decodedResponse = try JSONDecoder().decode(
            GoogleFontsMetadata.self,
            from: data
        )
        self.availableFontFamilies = decodedResponse.familyMetadataList.map(
            \.family
        )
    }

    func downloadAndRegisterFontFamily(_ family: String) async throws {
        self.downloading = false
        self.error = nil
        self.lastDownloadURL = nil

        guard !self.registeredFontFamily.contains(family) else {
            return
        }

        guard
            var components = URLComponents(
                string: downloadBaseURL
            )
        else {
            throw FontError.urlCreationFailed
        }

        components.queryItems = [
            URLQueryItem(name: "family", value: family)
        ]

        guard let url = components.url else {
            throw FontError.urlCreationFailed
        }

        let request = URLRequest(url: url)
        self.webview.load(request)
        self.downloading = true

        try await waitForDownload()
        if let error {
            throw FontError.failToDownload(error)
        }
        guard let lastDownloadURL else {
            throw FontError.failToDownload(nil)
        }

        let ttfFiles = try Self.extractTTF(from: lastDownloadURL)

        if ttfFiles.isEmpty {
            throw FontError.failToDownload(nil)
        }

        try Self.registerCustomFont(ttfURLs: ttfFiles)
        self.registeredFontFamily.insert(family)
    }

    private func waitForDownload() async throws {
        try await withTimeout(
            seconds: 5,
            operation: {
                while self.downloading {
                    if !self.downloading {
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            },
            cancellationError: CancellationError()
        )
    }

    private static func extractTTF(from zip: URL) throws -> [URL] {
        let fileManager = FileManager.default

        let destinationTemp = URL.temporaryDirectory.appendingPathComponent(
            "unzipped/"
        )

        try removeFileIfExists(at: destinationTemp)

        try fileManager.createDirectory(
            at: destinationTemp,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try fileManager.unzipItem(at: zip, to: destinationTemp)
        let ttfs = try self.getFiles(in: destinationTemp, withExtension: "ttf")
        return ttfs
    }

    private static func getFiles(in folderURL: URL, withExtension ext: String)
        throws -> [URL]
    {
        let fileManager = FileManager.default

        let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )

        return contents.filter {
            $0.pathExtension.lowercased() == ext.lowercased()
        }
    }

    private static func removeFileIfExists(at path: URL) throws {
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private static func registerCustomFont(
        ttfURLs: [URL],
        scope: CTFontManagerScope = .process
    ) throws {
        var error: [NSError] = []
        CTFontManagerRegisterFontURLs(
            ttfURLs as CFArray,
            scope,
            true,
            { errors, done in
                if let errors = errors as? [NSError], !errors.isEmpty {
                    error = errors
                    return false
                }

                return true
            }
        )

        if !error.isEmpty {
            throw FontError.failToRegisterFont(error)
        }
    }

}

extension GoogleFontProvider: WKNavigationDelegate, WKDownloadDelegate {

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let fileManager = FileManager.default
        do {
            try Self.removeFileIfExists(at: destinationFolder)
            try fileManager.createDirectory(
                at: destinationFolder,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let destinationURL = destinationFolder.appendingPathComponent(
                suggestedFilename
            )
            self.lastDownloadURL = destinationURL
            return destinationURL
        } catch (let error) {
            self.error = error
            self.downloading = false
            return nil
        }
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func downloadDidFinish(_ download: WKDownload) {
        self.downloading = false
        self.error = nil
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        self.downloading = false
        self.error = error
        self.lastDownloadURL = nil
    }

}

enum FontError: Error, LocalizedError {
    case urlCreationFailed
    case networkError(code: Int?)
    case ttfFileNotFound
    case timeout
    case failToDownload(Error?)
    case failToRegisterFont([Error])

    var errorDescription: String? {
        switch self {
        case .urlCreationFailed:
            "Fail to create URL."
        case .networkError(let statusCode):
            "Networking failed with status code: \(statusCode,  default: "(unknown)")."
        case .ttfFileNotFound:
            "Failed to get TTF file for the given font family."
        case .timeout:
            "The request timed out."
        case .failToDownload(let error):
            "Failed to download the font. \(error?.localizedDescription, default: "(unknown error)")"
        case .failToRegisterFont(let errors):
            "Failed to register fonts. \(errors.map(\.localizedDescription).joined(separator: "\n"))"
        }
    }
}

struct FontFamily: Codable, Identifiable {
    var id: String { family }
    let family: String
    let displayName: String?
}

// Wrapper for the top-level JSON response
struct GoogleFontsMetadata: Codable {
    let familyMetadataList: [FontFamily]
}

extension HTTPURLResponse {
    public var isSuccess: Bool {
        return (200...299).contains(self.statusCode)
    }
}

func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T,
    cancellationError: Error,
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw cancellationError
        }
        guard let result = try await group.next() else {
            group.cancelAll()
            throw cancellationError
        }
        group.cancelAll()
        return result
    }
}
