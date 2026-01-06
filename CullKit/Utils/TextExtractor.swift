//
//  TextExtractor.swift
//  CullKit
//
//  Native text extraction from PDFs and documents using Apple frameworks
//  Uses PDFKit for PDFs and NSAttributedString for rich text documents
//

import Foundation
import PDFKit
import os

/// Extracts text from various document types using native Apple frameworks
public actor TextExtractor {
    public static let shared = TextExtractor()

    private let logger = Logger(subsystem: "com.cull.mail", category: "textExtractor")

    private init() {}

    // MARK: - Public API

    /// Extract text from a file at the given URL
    public func extractText(from url: URL) async throws -> String {
        let fileExtension = url.pathExtension.lowercased()

        switch fileExtension {
        case "pdf":
            return try await extractTextFromPDF(url: url)
        case "txt":
            return try await extractTextFromPlainText(url: url)
        case "rtf", "rtfd":
            return try await extractTextFromRichText(url: url)
        case "doc", "docx":
            // For Word docs, try to extract as rich text (works for some formats)
            return try await extractTextFromRichText(url: url)
        default:
            throw TextExtractorError.unsupportedFormat(fileExtension)
        }
    }

    /// Extract text from raw data with a specified MIME type
    public func extractText(from data: Data, mimeType: String, filename: String) async throws -> String {
        let fileExtension = (filename as NSString).pathExtension.lowercased()

        if mimeType.contains("pdf") || fileExtension == "pdf" {
            return try await extractTextFromPDFData(data)
        } else if mimeType.contains("text/plain") || fileExtension == "txt" {
            return String(data: data, encoding: .utf8) ?? ""
        } else if mimeType.contains("rtf") || ["rtf", "rtfd"].contains(fileExtension) {
            return try await extractTextFromRichTextData(data)
        } else {
            throw TextExtractorError.unsupportedFormat(mimeType)
        }
    }

    // MARK: - PDF Extraction

    private func extractTextFromPDF(url: URL) async throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw TextExtractorError.failedToLoad
        }
        return extractTextFromPDFDocument(document)
    }

    private func extractTextFromPDFData(_ data: Data) async throws -> String {
        guard let document = PDFDocument(data: data) else {
            throw TextExtractorError.failedToLoad
        }
        return extractTextFromPDFDocument(document)
    }

    private func extractTextFromPDFDocument(_ document: PDFDocument) -> String {
        var fullText = ""

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            if let pageText = page.string {
                fullText += pageText
                fullText += "\n\n"
            }
        }

        // Clean up the extracted text
        return cleanExtractedText(fullText)
    }

    // MARK: - Plain Text Extraction

    private func extractTextFromPlainText(url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Rich Text Extraction

    private func extractTextFromRichText(url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        return try await extractTextFromRichTextData(data)
    }

    private func extractTextFromRichTextData(_ data: Data) async throws -> String {
        // Try RTF first
        if let attributedString = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return cleanExtractedText(attributedString.string)
        }

        // Try RTFD
        if let attributedString = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        ) {
            return cleanExtractedText(attributedString.string)
        }

        // Try Word doc (sometimes works with NSAttributedString)
        if let attributedString = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.docFormat],
            documentAttributes: nil
        ) {
            return cleanExtractedText(attributedString.string)
        }

        // Try plain text as fallback
        if let string = String(data: data, encoding: .utf8) {
            return cleanExtractedText(string)
        }

        throw TextExtractorError.failedToExtract
    }

    // MARK: - Text Cleanup

    private func cleanExtractedText(_ text: String) -> String {
        var cleaned = text

        // Normalize whitespace
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // Remove excessive newlines (keep max 2)
        cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        // Remove control characters except newlines and tabs
        cleaned = cleaned.filter { char in
            char.isLetter || char.isNumber || char.isWhitespace || char.isPunctuation || char.isSymbol
        }

        // Trim
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }
}

// MARK: - Errors

public enum TextExtractorError: Error, LocalizedError {
    case unsupportedFormat(String)
    case failedToLoad
    case failedToExtract

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported document format: \(format)"
        case .failedToLoad:
            return "Failed to load document"
        case .failedToExtract:
            return "Failed to extract text from document"
        }
    }
}

// MARK: - Attachment Extension

extension Attachment {
    /// Extract text from this attachment if it's a supported document type
    /// Returns nil if the attachment type doesn't support text extraction
    public func extractText(from data: Data) async -> String? {
        guard isTextExtractable else { return nil }

        do {
            let text = try await TextExtractor.shared.extractText(
                from: data,
                mimeType: mimeType ?? "",
                filename: filename
            )
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
