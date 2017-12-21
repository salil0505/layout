//  Copyright © 2017 Schibsted. All rights reserved.

import Foundation

/// An enumeration of the types of error that may be thrown by LayoutTool
enum FormatError: Error, CustomStringConvertible {
    case reading(String)
    case writing(String)
    case parsing(String)
    case options(String)
    case generic(String)

    public init(_ error: Error) {
        switch error {
        case let error as FormatError:
            self = error
        case let error as XMLParser.Error:
            self = .parsing(error.description)
        default:
            self = .generic(error.localizedDescription)
        }
    }

    public var description: String {
        switch self {
        case let .reading(string),
             let .writing(string),
             let .parsing(string),
             let .options(string),
             let .generic(string):
            return string
        }
    }

    /// Converts error thrown by the wrapped closure to a LayoutError
    public static func wrap<T>(_ closure: () throws -> T) throws -> T {
        do {
            return try closure()
        } catch {
            throw self.init(error)
        }
    }
}

/// File enumeration options
struct FileOptions {
    public var followSymlinks: Bool
    public var supportedFileExtensions: [String]

    public init(followSymlinks: Bool = false,
                supportedFileExtensions: [String] = ["xml"]) {

        self.followSymlinks = followSymlinks
        self.supportedFileExtensions = supportedFileExtensions
    }
}

/// Enumerate all xml files at the specified location and (optionally) calculate an output file URL for each.
/// Ignores the file if any of the excluded file URLs is a prefix of the input file URL.
///
/// Files are enumerated concurrently. For convenience, the enumeration block returns a completion block, which
/// will be executed synchronously on the calling thread once enumeration is complete.
///
/// Errors may be thrown by either the enumeration block or the completion block, and are gathered into an
/// array and returned after enumeration is complete, along with any errors generated by the function itself.
/// Throwing an error from inside either block does *not* terminate the enumeration.
func enumerateFiles(withInputURL inputURL: URL,
                    excluding excludedURLs: [URL] = [],
                    outputURL: URL? = nil,
                    options: FileOptions = FileOptions(),
                    concurrent: Bool = true,
                    block: @escaping (URL, URL) throws -> () throws -> Void) -> [Error] {

    guard let resourceValues = try? inputURL.resourceValues(
        forKeys: Set([.isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey])) else {
        if FileManager.default.fileExists(atPath: inputURL.path) {
            return [FormatError.reading("failed to read attributes for \(inputURL.path)")]
        }
        return [FormatError.options("file not found at \(inputURL.path)")]
    }
    if !options.followSymlinks &&
        (resourceValues.isAliasFile == true || resourceValues.isSymbolicLink == true) {
        return [FormatError.options("symbolic link or alias was skipped: \(inputURL.path)")]
    }
    if resourceValues.isDirectory == false &&
        !options.supportedFileExtensions.contains(inputURL.pathExtension) {
        return [FormatError.options("unsupported file type: \(inputURL.path)")]
    }

    let group = DispatchGroup()
    var completionBlocks = [() throws -> Void]()
    let completionQueue = DispatchQueue(label: "layout.enumeration")
    func onComplete(_ block: @escaping () throws -> Void) {
        completionQueue.async(group: group) {
            completionBlocks.append(block)
        }
    }

    let manager = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey]
    let queue = concurrent ? DispatchQueue.global(qos: .userInitiated) : completionQueue

    func enumerate(inputURL: URL,
                   excluding excludedURLs: [URL],
                   outputURL: URL?,
                   options: FileOptions,
                   block: @escaping (URL, URL) throws -> () throws -> Void) {

        for excludedURL in excludedURLs {
            if inputURL.absoluteString.hasPrefix(excludedURL.absoluteString) {
                return
            }
        }
        guard let resourceValues = try? inputURL.resourceValues(forKeys: Set(keys)) else {
            onComplete { throw FormatError.reading("failed to read attributes for \(inputURL.path)") }
            return
        }
        if resourceValues.isRegularFile == true {
            if options.supportedFileExtensions.contains(inputURL.pathExtension) {
                do {
                    onComplete(try block(inputURL, outputURL ?? inputURL))
                } catch {
                    onComplete { throw error }
                }
            }
        } else if resourceValues.isDirectory == true {
            var excludedURLs = excludedURLs
            let ignoreFile = inputURL.appendingPathComponent(layoutIgnoreFile)
            if manager.fileExists(atPath: ignoreFile.path) {
                do {
                    excludedURLs += try parseIgnoreFile(ignoreFile)
                } catch {
                    onComplete { throw error }
                }
            }
            guard let files = try? manager.contentsOfDirectory(
                at: inputURL, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else {
                onComplete { throw FormatError.reading("failed to read contents of directory at \(inputURL.path)") }
                return
            }
            for url in files {
                queue.async(group: group) {
                    let outputURL = outputURL.map {
                        URL(fileURLWithPath: $0.path + String(url.path[inputURL.path.endIndex ..< url.path.endIndex]))
                    }
                    enumerate(inputURL: url,
                              excluding: excludedURLs,
                              outputURL: outputURL,
                              options: options,
                              block: block)
                }
            }
        } else if options.followSymlinks &&
            (resourceValues.isSymbolicLink == true || resourceValues.isAliasFile == true) {
            let resolvedURL = inputURL.resolvingSymlinksInPath()
            enumerate(inputURL: resolvedURL,
                      excluding: excludedURLs,
                      outputURL: outputURL,
                      options: options,
                      block: block)
        }
    }

    queue.async(group: group) {
        if !manager.fileExists(atPath: inputURL.path) {
            onComplete { throw FormatError.options("file not found at \(inputURL.path)") }
            return
        }
        enumerate(inputURL: inputURL,
                  excluding: excludedURLs,
                  outputURL: outputURL,
                  options: options,
                  block: block)
    }
    group.wait()

    var errors = [Error]()
    for block in completionBlocks {
        do {
            try block()
        } catch {
            errors.append(error)
        }
    }
    return errors
}

func expandPath(_ path: String) -> URL {
    let path = NSString(string: path).expandingTildeInPath
    let directoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return URL(fileURLWithPath: path, relativeTo: directoryURL)
}

func parseLayoutXML(_ data: Data, for fileURL: URL) throws -> [XMLNode]? {
    do {
        let xml = try XMLParser.parse(data: data)
        return xml.isLayout ? xml : nil
    } catch {
        switch error {
        case let error as XMLParser.Error:
            throw FormatError.parsing("\(error) in \(fileURL.path)")
        case let error as FileError:
            throw FormatError.parsing(error.description)
        default:
            throw FormatError.reading(error.localizedDescription)
        }
    }
}

func parseLayoutXML(_ fileURL: URL) throws -> [XMLNode]? {
    let data = try Data(contentsOf: fileURL)
    return try parseLayoutXML(data, for: fileURL)
}

// Currently only used for testing
func parseXML(_ xml: String) throws -> [XMLNode] {
    guard let data = xml.data(using: .utf8, allowLossyConversion: true) else {
        throw FormatError.parsing("Invalid xml string")
    }
    return try FormatError.wrap { try XMLParser.parse(data: data) }
}

func list(_ files: [String]) -> [FormatError] {
    var errors = [Error]()
    for path in files {
        let url = expandPath(path)
        errors += enumerateFiles(withInputURL: url, concurrent: false) { inputURL, _ in
            do {
                guard try parseLayoutXML(inputURL) != nil else {
                    return {}
                }
                return {
                    print(inputURL.path[url.path.endIndex ..< inputURL.path.endIndex])
                }
            } catch {
                return { throw error }
            }
        }
    }
    return errors.map(FormatError.init)
}

// Determines if given type should be treated as a string expression
func isStringType(_ name: String) -> Bool {
    return [
        "String", "NSString",
        "Selector",
        "NSAttributedString",
        "URL", "NSURL",
        "UIImage", "CGImage",
        "UIColor", "CGColor", // NOTE: special case handling
        "UIFont",
    ].contains(name)
}

// Returns the type name of an attribute in a node, or nil if uncertain
func typeOfAttribute(_ key: String, inNode node: XMLNode) -> String? {
    func typeForClass(_ className: String) -> String? {
        switch key {
        case "outlet", "id":
            return "String"
        case "xml", "template":
            return "URL"
        case "left", "right", "width", "top", "bottom", "height", "center.x", "center.y":
            return "CGFloat"
        default:
            // Look up the type
            if let props = UIKitSymbols[className] {
                if let type = props[key] {
                    return type
                } else if let superclass = props["superclass"], let type = typeForClass(superclass) {
                    return type
                }
            }
            if className.hasSuffix("Controller"), let type = UIKitSymbols["UIViewController"]![key] {
                return type
            }
            if let type = UIKitSymbols["UIView"]![key] {
                return type
            }
            // Guess the type from the name
            switch key.components(separatedBy: ".").last! {
            case "left", "right", "x", "width", "top", "bottom", "y", "height":
                return "CGFloat"
            case _ where key.hasPrefix("is") || key.hasPrefix("has"):
                return "Bool"
            case _ where key.hasSuffix("Color"), "color":
                return "UIColor"
            case _ where key.hasSuffix("Size"), "size":
                return "CGSize"
            case _ where key.hasSuffix("Delegate"), "delegate",
                 _ where key.hasSuffix("DataSource"), "dataSource":
                return "Protocol"
            default:
                return nil
            }
        }
    }
    if let type = node.parameters[key] {
        return type
    }
    guard let className = node.name else {
        preconditionFailure()
    }
    return typeForClass(className)
}

// Determines if given attribute should be treated as a string expression
// Returns true or false if reasonably certain, otherwise returns nil
func attributeIsString(_ key: String, inNode node: XMLNode) -> Bool? {
    guard let type = typeOfAttribute(key, inNode: node) else {
        return nil
    }
    switch type {
    case "UIColor", "CGColor":
        if let expression = node.attributes[key], !expression.contains("{"),
            expression.contains("rgb(") || expression.contains("rgba(") {
            return false
        }
        return true
    default:
        return isStringType(type)
    }
}

// Check that the expression symbols are valid (or at least plausible)
func validateLayoutExpression(_ parsedExpression: ParsedLayoutExpression) throws {
    if let error = parsedExpression.error, error != .unexpectedToken("") {
        throw error
    }
    let keys = Set(Expression.mathSymbols.keys).union(Expression.boolSymbols.keys).union([
        .postfix("%"),
        .function("rgb", arity: 3),
        .function("rgba", arity: 4),
    ])
    for symbol in parsedExpression.symbols {
        switch symbol {
        case .variable, .array:
            break
        case .prefix, .infix, .postfix:
            guard keys.contains(symbol) else {
                throw Expression.Error.undefinedSymbol(symbol)
            }
        case let .function(called, arity):
            guard keys.contains(symbol) else {
                for case let .function(name, requiredArity) in keys
                    where name == called && arity != requiredArity {
                    throw Expression.Error.arityMismatch(.function(called, arity: requiredArity))
                }
                throw Expression.Error.undefinedSymbol(symbol)
            }
        }
    }
}

// Print parsed expression
extension ParsedExpressionPart: CustomStringConvertible {
    var description: String {
        switch self {
        case let .string(string):
            return string
        case let .comment(comment):
            return "// \(comment)"
        case let .expression(expression):
            return "{\(expression)}"
        }
    }
}
