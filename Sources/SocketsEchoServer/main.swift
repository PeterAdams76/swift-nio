//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Sockets

public class Buffer {
    var data: Data
    var offset: Int
    var limit: Int
    
    init(capacity: Int32) {
        self.data = Data(repeating: 0, count: Int(capacity))
        self.offset = 0
        self.limit = 0;
    }
    
    public func clear() {
        self.offset = 0
        self.limit = 0
    }
}

func deregisterAndClose(selector: Sockets.Selector, s: Selectable) {
    do { try selector.deregister(selectable: s) } catch {}
    do { try s.close() } catch {}
}


// Bootstrap the server and create the Selector on which we register our sockets.
let selector = try Sockets.Selector()

defer {
    do { try selector.close() } catch { }
}

let server = try ServerSocket.bootstrap(host: "0.0.0.0", port: 9096)
try server.setNonBlocking()


// this will register with InterestedEvent.READ and no attachment
try selector.register(selectable: server)

// cleanup
defer {
    do { try selector.deregister(selectable: server) } catch { }
    do { try server.close() } catch { }
}

try server.setOption(level: SOL_SOCKET, name: SO_REUSEADDR, value: 1)

while true {
    // Block until there are events to handle
    if let events = try selector.awaitReady() {
        for ev in events {
            if ev.isReadable {
                
                // We can handle either read(...) or accept()
                if ev.selectable is Socket {
                    // We stored the Buffer before as attachment so get it and clear the limit / offset.
                    let buffer = ev.attachment as! Buffer
                    buffer.clear()
                    
                    let s = ev.selectable as! Socket
                    do {
                        if let read = try s.read(data: &buffer.data) {
                            buffer.limit = Int(read)
                            
                            if let written = try s.write(data: buffer.data, offset: buffer.offset, len: buffer.limit - buffer.offset) {
                                buffer.offset += Int(written)
                                
                                // We could not write everything so we reregister with InterestedEvent.Write and so get woken up once the socket becomes writable again.
                                // This also ensure we not read anymore until we were able to echo it back (backpressure FTW).
                                if buffer.offset < buffer.limit {
                                    try selector.reregister(selectable: s, interested: InterestedEvent.Write)
                                }
                                
                            } else {
                                // We could not write everything so we reregister with InterestedEvent.Write and so get woken up once the socket becomes writable again.
                                // This also ensure we not read anymore until we were able to echo it back (backpressure FTW).
                                try selector.reregister(selectable: s, interested: InterestedEvent.Write)
                            }
                            
                        }
                    } catch {
                        deregisterAndClose(selector: selector, s: s)
                    }
                } else if ev.selectable is ServerSocket {
                    let socket = ev.selectable as! ServerSocket
                    
                    // Accept new connections until there are no more in the backlog
                    while let accepted = try socket.accept() {
                        try accepted.setNonBlocking()
                        try accepted.setOption(level: SOL_SOCKET, name: SO_REUSEADDR, value: 1)
                        
                        
                        // Allocate an 8kb buffer for reading and writing and register the socket with the selector
                        let buffer = Buffer(capacity: 8 * 1024)
                        try selector.register(selectable: accepted, attachment: buffer)
                    }
                }
            } else if ev.isWritable {
                if ev.selectable is Socket {
                    let buffer = ev.attachment as! Buffer
                    
                    let s = ev.selectable as! Socket
                    do {
                        if let written = try s.write(data: buffer.data, offset: buffer.offset, len: buffer.limit - buffer.offset) {
                            buffer.offset += Int(written)
                            
                            if buffer.offset == buffer.limit {
                                // Everything was written, reregister again with InterestedEvent.Read so we are notified once there is more data on the socket to read.
                                try selector.reregister(selectable: s, interested: InterestedEvent.Read)
                            }
                        }
                    } catch {
                        deregisterAndClose(selector: selector, s: s)
                    }
                }
            }
        }
    }
}
