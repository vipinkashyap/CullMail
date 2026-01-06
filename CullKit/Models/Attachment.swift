//
//  Attachment.swift
//  CullKit
//
//  Attachment model for email attachments with category detection
//  and text extraction support for semantic search
//

import Foundation
import GRDB

// MARK: - Attachment Category

/// Categories for automatic attachment classification
/// Used for smart filing and search
public enum AttachmentCategory: String, Codable, CaseIterable, Sendable {
    case invoice       // Bills, invoices, payment requests
    case receipt       // Purchase receipts, order confirmations
    case ticket        // Travel tickets, event tickets, boarding passes
    case contract      // Contracts, agreements, legal documents
    case statement     // Bank statements, account statements
    case report        // Reports, presentations
    case image         // Photos, screenshots
    case document      // Generic documents
    case spreadsheet   // Excel, CSV, numbers files
    case archive       // ZIP, RAR, compressed files
    case other         // Uncategorized

    public var displayName: String {
        switch self {
        case .invoice: return "Invoice"
        case .receipt: return "Receipt"
        case .ticket: return "Ticket"
        case .contract: return "Contract"
        case .statement: return "Statement"
        case .report: return "Report"
        case .image: return "Image"
        case .document: return "Document"
        case .spreadsheet: return "Spreadsheet"
        case .archive: return "Archive"
        case .other: return "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .invoice: return "doc.text"
        case .receipt: return "receipt"
        case .ticket: return "ticket"
        case .contract: return "signature"
        case .statement: return "chart.bar.doc.horizontal"
        case .report: return "doc.richtext"
        case .image: return "photo"
        case .document: return "doc"
        case .spreadsheet: return "tablecells"
        case .archive: return "archivebox"
        case .other: return "paperclip"
        }
    }

    /// Detect category from filename and MIME type
    public static func detect(filename: String, mimeType: String?) -> AttachmentCategory {
        let lowerFilename = filename.lowercased()
        let lowerMime = mimeType?.lowercased() ?? ""

        // Check filename patterns first (most reliable)
        if lowerFilename.contains("invoice") || lowerFilename.contains("bill") {
            return .invoice
        }
        if lowerFilename.contains("receipt") || lowerFilename.contains("order") {
            return .receipt
        }
        if lowerFilename.contains("ticket") || lowerFilename.contains("boarding") ||
           lowerFilename.contains("itinerary") || lowerFilename.contains("confirmation") {
            return .ticket
        }
        if lowerFilename.contains("contract") || lowerFilename.contains("agreement") ||
           lowerFilename.contains("terms") || lowerFilename.contains("signed") {
            return .contract
        }
        if lowerFilename.contains("statement") || lowerFilename.contains("account") {
            return .statement
        }
        if lowerFilename.contains("report") || lowerFilename.contains("presentation") {
            return .report
        }

        // Check MIME type
        if lowerMime.contains("image") {
            return .image
        }
        if lowerMime.contains("spreadsheet") || lowerMime.contains("excel") ||
           lowerFilename.hasSuffix(".xlsx") || lowerFilename.hasSuffix(".xls") ||
           lowerFilename.hasSuffix(".csv") || lowerFilename.hasSuffix(".numbers") {
            return .spreadsheet
        }
        if lowerMime.contains("zip") || lowerMime.contains("compressed") ||
           lowerMime.contains("archive") || lowerFilename.hasSuffix(".zip") ||
           lowerFilename.hasSuffix(".rar") || lowerFilename.hasSuffix(".7z") {
            return .archive
        }
        if lowerMime.contains("pdf") || lowerMime.contains("document") ||
           lowerMime.contains("word") || lowerFilename.hasSuffix(".pdf") ||
           lowerFilename.hasSuffix(".doc") || lowerFilename.hasSuffix(".docx") {
            return .document
        }

        return .other
    }
}

// MARK: - Attachment Model

/// Represents an email attachment with metadata and optional extracted content
public struct Attachment: Identifiable, Codable, Sendable {
    /// Unique identifier (Gmail attachment ID or UUID for local)
    public let id: String

    /// Parent email ID
    public let emailId: String

    /// Original filename
    public let filename: String

    /// MIME type (e.g., "application/pdf", "image/jpeg")
    public let mimeType: String?

    /// Size in bytes
    public let sizeBytes: Int

    /// Detected category for smart filing
    public var category: AttachmentCategory

    /// Extracted text content (for PDFs, documents) - used for search
    public var extractedText: String?

    /// Google Drive file ID if uploaded
    public var driveFileId: String?

    /// When uploaded to Drive (nil if not uploaded)
    public var uploadedAt: Date?

    /// Local file path if downloaded (relative to app support directory)
    public var localPath: String?

    /// Whether text has been extracted
    public var isTextExtracted: Bool

    /// When the attachment was first seen
    public let createdAt: Date

    /// Last update timestamp
    public var updatedAt: Date

    // MARK: - Initialization

    public init(
        id: String,
        emailId: String,
        filename: String,
        mimeType: String?,
        sizeBytes: Int,
        category: AttachmentCategory? = nil,
        extractedText: String? = nil,
        driveFileId: String? = nil,
        uploadedAt: Date? = nil,
        localPath: String? = nil,
        isTextExtracted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.emailId = emailId
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.category = category ?? AttachmentCategory.detect(filename: filename, mimeType: mimeType)
        self.extractedText = extractedText
        self.driveFileId = driveFileId
        self.uploadedAt = uploadedAt
        self.localPath = localPath
        self.isTextExtracted = isTextExtracted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Computed Properties

    /// Human-readable file size
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    /// File extension
    public var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }

    /// Whether this is a PDF
    public var isPDF: Bool {
        fileExtension == "pdf" || mimeType?.contains("pdf") == true
    }

    /// Whether this is an image
    public var isImage: Bool {
        mimeType?.hasPrefix("image/") == true ||
        ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(fileExtension)
    }

    /// Whether this attachment can have text extracted
    public var isTextExtractable: Bool {
        isPDF ||
        ["doc", "docx", "txt", "rtf"].contains(fileExtension) ||
        mimeType?.contains("text") == true
    }

    /// Whether this is uploaded to Drive
    public var isUploadedToDrive: Bool {
        driveFileId != nil
    }

    /// Whether this is downloaded locally
    public var isDownloaded: Bool {
        localPath != nil
    }
}

// MARK: - GRDB Conformance

extension Attachment: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "attachments" }

    public enum Columns {
        static let id = Column(CodingKeys.id)
        static let emailId = Column(CodingKeys.emailId)
        static let filename = Column(CodingKeys.filename)
        static let mimeType = Column(CodingKeys.mimeType)
        static let sizeBytes = Column(CodingKeys.sizeBytes)
        static let category = Column(CodingKeys.category)
        static let extractedText = Column(CodingKeys.extractedText)
        static let driveFileId = Column(CodingKeys.driveFileId)
        static let uploadedAt = Column(CodingKeys.uploadedAt)
        static let localPath = Column(CodingKeys.localPath)
        static let isTextExtracted = Column(CodingKeys.isTextExtracted)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

// MARK: - Hashable & Equatable

extension Attachment: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Attachment, rhs: Attachment) -> Bool {
        lhs.id == rhs.id
    }
}
