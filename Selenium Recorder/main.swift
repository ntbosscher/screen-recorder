//
//  main.swift
//  Selenium Recorder
//
//  Created by nate bosscher on 2022-12-20.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

let args = CommandLine.arguments;
var pid = 0;
var outputFileName = "output-2.mp4";
let processRegexp = Regex(/--process=([0-9]+)/)
let fileRegexp = Regex(/--output=(.+)/)

func nthMatch(regex: Regex<AnyRegexOutput>, input: String, nth: Int) -> String? {
    guard let results = input.firstMatch(of: regex) else {
        return nil
    }
    
    if results.output.count <= nth {
        return nil
    }
    
    guard let raw = results.output[nth].substring else {
        return nil
    }
    
    return String(raw)
}

for arg in CommandLine.arguments[1...] {
    if let fileStr = nthMatch(regex: fileRegexp, input: arg, nth: 1) {
        outputFileName = fileStr
        continue
    }
    
    if let pidStr = nthMatch(regex: processRegexp, input: arg, nth: 1) {
        pid = Int(pidStr) ?? 0
    }
}

print("Screen Capture: natebosscher @2022")

if pid == 0 {
    print("Failed to parse args:")
    print("   --process=000")
    exit(-1)
}

CGRequestScreenCaptureAccess()

let availableContent: SCShareableContent;

do {
    availableContent = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly: true);
} catch {
    print("Failed to get available windows. Check your screen permissions.")
    print(error)
    exit(-1);
}

guard let chrome = availableContent.applications.first(where: { $0.processID == pid }) else {
    print("Can't find process with PID=\(pid)")
    
    print("Found:")
    for app in availableContent.applications {
        print("  \(app.bundleIdentifier) \(app.processID)")
    }
    
    exit(-1)
}

let excludeApps = availableContent.applications.filter { $0 != chrome }
let windows = availableContent.windows.filter({
    $0.isOnScreen && $0.owningApplication?.processID == chrome.processID && $0.title != ""
})

guard let primaryWindow = windows.first else {
    print("can't find any windows for \(chrome.processID) \(chrome.bundleIdentifier) that are on screen and have a title")
    exit(-1)
}

guard let selectedDisplay = availableContent.displays.filter({
        $0.frame.contains(primaryWindow.frame.origin)
    }).first else {
    
    print("No display")
    exit(-1)
}

print("display: \(selectedDisplay.frame)")
print("window: \(primaryWindow.frame) \(primaryWindow.title)")

let filter = SCContentFilter(display: selectedDisplay, including: availableContent.windows)

let streamConfig = SCStreamConfiguration()
streamConfig.capturesAudio = false

let scaleFactor = Int(NSScreen.main?.backingScaleFactor ?? 1);

// setup size
streamConfig.width = Int(selectedDisplay.frame.width) * scaleFactor
streamConfig.height = Int(selectedDisplay.frame.height) * scaleFactor

// Set the capture interval at 60 fps.
streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 60)

// Increase the depth of the frame queue to ensure high fps at the expense of increasing
// the memory footprint of WindowServer.
streamConfig.queueDepth = 6

let stream = Streamer(outputFileName: outputFileName, streamConfig: streamConfig, filter: filter)
stream.start()

signal(SIGINT, SIG_IGN)

var run = true;
let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler {
    print("Received shutdown signal")
    run = false;
}

sigintSrc.resume()

while run {
    try await Task.sleep(nanoseconds: 1_000_000)
}

stream.stop()
    
class Streamer: NSObject, SCStreamDelegate, SCStreamOutput {
    
    var assetWriterVideoInput: AVAssetWriterInput
    var assetWriter: AVAssetWriter
    var stream: SCStream?
    var file: URL
    var lastTimestamp: CMTime = CMTime(value: 0, timescale: 600)
    var hasSession = false
    var sampleQueue = DispatchQueue(label: "nate.SampleHandlerQueue")
    var streamConfig: SCStreamConfiguration
    var filter: SCContentFilter
    var dropCount = 0
    
    init(outputFileName: String, streamConfig: SCStreamConfiguration, filter: SCContentFilter) {
        file = URL(fileURLWithPath: outputFileName)
        self.streamConfig = streamConfig
        self.filter = filter
    
        // remove old file to prevent issues with AVAssetWriter
        if FileManager.default.fileExists(atPath: self.file.relativePath) {
            do {
                try FileManager.default.removeItem(at: self.file)
            } catch {}
        }
        
        guard let writer = try? AVAssetWriter(url: self.file, fileType: .mp4) else {
            print("failed to start writer for output file")
            exit(-1)
        }
        
        self.assetWriter = writer

        // Add a video input
        self.assetWriterVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey : AVVideoCodecType.h264,
            AVVideoWidthKey : NSNumber(value: streamConfig.width),
            AVVideoHeightKey : NSNumber(value: streamConfig.height)
        ])
        
        self.assetWriterVideoInput.expectsMediaDataInRealTime = true
        
        assetWriter.add(assetWriterVideoInput)
        assetWriter.startWriting()
    }
    
    func start() {
        // Add a stream output to capture screen content.
        do {
            stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
            try stream?.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: self.sampleQueue)
        } catch {
            print("failed to add video output stream")
            print(error)
        }
        
        stream?.startCapture()
    }
    
    func stop() {
        let group = DispatchGroup()
        group.enter()
        
        stream?.stopCapture(completionHandler: {e in
            if e != nil {
                print("failed to stop correctly")
                print(e)
            }
            
            self.assetWriterVideoInput.markAsFinished()
            self.assetWriter.finishWriting(completionHandler: {
                group.leave()
            })
        })
        
        group.wait()
        print("wrote: \(file.absoluteURL)")
        if dropCount > 0 {
            print("dropped frames: \(dropCount)")
        }
    }
    
    func stream(_ stream: SCStream,
                      didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                      of type: SCStreamOutputType) {
        
        // Return early if the sample buffer is invalid.
        guard sampleBuffer.isValid else { return }
        
        let writer = assetWriter
        let input = assetWriterVideoInput
        
        // Determine which type of data the sample buffer contains.
        switch type {
        case SCStreamOutputType.screen:
            switch writer.status {
            case .writing:
                if !hasSession {
                    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    hasSession = true
                }
                
                if input.isReadyForMoreMediaData {
                    self.lastTimestamp = sampleBuffer.presentationTimeStamp
                    
                    // by some wizardry this prevents .append() from failing
                    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                            let attachment = attachments.first,
                            let contentRectDict = attachment[.contentRect],
                            let contentRect = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary)
                    else {
                        return
                    }
                    
                    if !input.append(sampleBuffer) {
                        print("failed to append buffer")
                    }
                } else {
                    dropCount += 1
                }
            case .failed:
                print("writer failed: Stopping capture prematurely")
                print(writer.error)
                stream.stopCapture()
            default:
                print("received frames while in unknown assetWriter state \(writer.status). dropping frame.")
            }
        case SCStreamOutputType.audio:
            print("got audio frame, but audio is disabled")
        default:
            print("unknown OutputType")
        }
    }
}




