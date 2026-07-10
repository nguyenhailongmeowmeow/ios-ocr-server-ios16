//
//  OCREngine.swift
//  OcrServer (iOS 12 Legacy)
//
//  Uses VNRecognizeTextRequest on iOS 13+, fallback message on iOS 12.
//

import Foundation
import UIKit
import Vision

// MARK: - Response Models

struct OCRBoxItem: Codable {
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

struct UploadResponse: Codable {
    let success: Bool
    let message: String
    let ocr_result: String
    let image_width: Int
    let image_height: Int
    let ocr_boxes: [OCRBoxItem]
}

// MARK: - OCR Engine

class OCREngine {
    
    var recognitionLevel: String = "Accurate" // "Accurate" or "Fast"
    var usesLanguageCorrection: Bool = true
    var automaticallyDetectsLanguage: Bool = true
    
    func recognizeText(from imageData: Data, completion: @escaping (UploadResponse) -> Void) {
        if #available(iOS 13.0, *) {
            performVisionOCR(imageData: imageData, completion: completion)
        } else {
            // iOS 12 does not support VNRecognizeTextRequest
            let response = UploadResponse(
                success: false,
                message: "OCR requires iOS 13 or later. This device is running iOS \(UIDevice.current.systemVersion).",
                ocr_result: "",
                image_width: 0,
                image_height: 0,
                ocr_boxes: []
            )
            DispatchQueue.main.async {
                completion(response)
            }
        }
    }
    
    // MARK: - Vision OCR (iOS 13+)
    
    @available(iOS 13.0, *)
    private func performVisionOCR(imageData: Data, completion: @escaping (UploadResponse) -> Void) {
        guard let (imgWidth, imgHeight) = imagePixelSize(from: imageData) else {
            let response = UploadResponse(
                success: false,
                message: "Failed to read image dimensions",
                ocr_result: "",
                image_width: 0,
                image_height: 0,
                ocr_boxes: []
            )
            completion(response)
            return
        }
        
        guard let cgImage = createCGImage(from: imageData) else {
            let response = UploadResponse(
                success: false,
                message: "Failed to create image from data",
                ocr_result: "",
                image_width: imgWidth,
                image_height: imgHeight,
                ocr_boxes: []
            )
            completion(response)
            return
        }
        
        let W = imgWidth
        let H = imgHeight
        let level = recognitionLevel
        let langCorrection = usesLanguageCorrection
        let autoDetect = automaticallyDetectsLanguage
        
        let request = VNRecognizeTextRequest { (request, error) in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                let response = UploadResponse(
                    success: false,
                    message: "OCR failed: \(error?.localizedDescription ?? "Unknown error")",
                    ocr_result: "",
                    image_width: W,
                    image_height: H,
                    ocr_boxes: []
                )
                completion(response)
                return
            }
            
            var lines: [String] = []
            var boxes: [OCRBoxItem] = []
            
            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let text = candidate.string
                lines.append(text)
                
                // Convert normalized bounding box to pixel coordinates
                // VNRecognizedTextObservation.boundingBox is in normalized coords (0-1)
                // Origin is bottom-left in Vision coordinates
                let bbox = obs.boundingBox
                let x = Double(bbox.origin.x * CGFloat(W))
                let y = Double((1.0 - bbox.origin.y - bbox.size.height) * CGFloat(H))
                let w = Double(bbox.size.width * CGFloat(W))
                let h = Double(bbox.size.height * CGFloat(H))
                
                boxes.append(OCRBoxItem(text: text, x: x, y: y, w: w, h: h))
            }
            
            let response = UploadResponse(
                success: true,
                message: "File uploaded successfully",
                ocr_result: lines.joined(separator: "\n"),
                image_width: W,
                image_height: H,
                ocr_boxes: boxes
            )
            completion(response)
        }
        
        // Configure the request
        request.recognitionLevel = (level == "Fast") ? .fast : .accurate
        request.usesLanguageCorrection = langCorrection
        
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = autoDetect
        }
        
        // Perform the request on a background queue
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                let response = UploadResponse(
                    success: false,
                    message: "OCR failed: \(error.localizedDescription)",
                    ocr_result: "",
                    image_width: W,
                    image_height: H,
                    ocr_boxes: []
                )
                completion(response)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func imagePixelSize(from data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            return nil
        }
        return (w, h)
    }
    
    private func createCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
