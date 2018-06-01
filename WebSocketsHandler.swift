//
//  PerfectHandlers.swift
//  WebSockets Server
//
//  Created by Kyle Jessup on 2016-01-06.
//  Copyright PerfectlySoft 2016. All rights reserved.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import PerfectLib
import PerfectWebSockets
import PerfectHTTP
import PerfectSMTP
import Foundation

func makeRoutes() -> Routes {
	var routes = Routes()
	routes.add(method: .get, uri: "*", handler: { request, response in
		StaticFileHandler(documentRoot: request.documentRoot).handleRequest(request: request, response: response)
	})
    
	routes.add(method: .get, uri: "/echo", handler: {
        request, response in
        
        WebSocketHandler(handlerProducer: {
            (request: HTTPRequest, protocols: [String]) -> WebSocketSessionHandler? in
   
            guard protocols.contains("echo") else {
                return nil
            }
            
            return EchoHandler()
        }).handleRequest(request: request, response: response)
    })
	
	return routes
}

// A WebSocket service handler must impliment the `WebSocketSessionHandler` protocol.
// This protocol requires the function `handleSession(request: WebRequest, socket: WebSocket)`.
// This function will be called once the WebSocket connection has been established,
// at which point it is safe to begin reading and writing messages.
//
// The initial `WebRequest` object which instigated the session is provided for reference.
// Messages are transmitted through the provided `WebSocket` object.
// Call `WebSocket.sendStringMessage` or `WebSocket.sendBinaryMessage` to send data to the client.
// Call `WebSocket.readStringMessage` or `WebSocket.readBinaryMessage` to read data from the client.
// By default, reading will block indefinitely until a message arrives or a network error occurs.
// A read timeout can be set with `WebSocket.readTimeoutSeconds`.
// When the session is over call `WebSocket.close()`.
class EchoHandler: WebSocketSessionHandler {
	
    var user: User? = nil
    
	let socketProtocol: String? = "echo"
	func handleSession(request: HTTPRequest, socket: WebSocket) {
        
        var responeMessage = "ok"
		
		// Read a message from the client as a String.
		// Alternatively we could call `WebSocket.readBytesMessage` to get binary data from the client.
		socket.readStringMessage {
			// This callback is provided:
			//	the received data
			//	the message's op-code
			//	a boolean indicating if the message is complete (as opposed to fragmented)
			string, op, fin in
			
			// The data parameter might be nil here if either a timeout or a network error, such as the client disconnecting, occurred.
			// By default there is no timeout.
			guard let string = string else {
				// This block will be executed if, for example, the browser window is closed.
				socket.close()
				return
			}
			
			// Print some information to the console for informational purposes.
			print("Read msg: \(string) op: \(op) fin: \(fin)")
            do {
                guard fin == true, let json = try string.jsonDecode() as? [String: Any] else {return}
                do {
                    let newUser = try User.init(json: json)
                    self.user = newUser
                } catch {
                    print("failed to create User. Maybe it's an email")
                    do {
                        let mail = try UserMessage(json: json, user: self.user!)
                        let status = mail.sendEmail()
                        responeMessage = (status ? "success":"failed")
                    }
                }
            } catch {
                print("Failed to decode JSON from Received Socket Message")
            }
			
			// Echo the data we received back to the client.
			// Pass true for final. This will usually be the case, but WebSockets has the concept of fragmented messages.
			// For example, if one were streaming a large file such as a video, one would pass false for final.
			// This indicates to the receiver that there is more data to come in subsequent messages but that all the data is part of the same logical message.
			// In such a scenario one would pass true for final only on the last bit of the video.
			socket.sendStringMessage(string: responeMessage, final: true) {
				// This callback is called once the message has been sent.
				// Recurse to read and echo new message.
				self.handleSession(request: request, socket: socket)
			}
		}
	}
}




enum UserError: Error {
    case failedToCreate
}
class User: Hashable {
    var hashValue: Int {
        return email.hashValue
    }
    static func ==(lhs: User, rhs: User) -> Bool {
        return lhs.email == rhs.email
    }
    
    let email:String
    let password:String
    
    init(json: [String: Any]) throws {
        
        guard let userEmail = json["email"] as? String, let userPassword = json["password"] as? String else { throw UserError.failedToCreate }
        
        self.email = userEmail
        self.password = userPassword
        
        print("User with email: " , email , " inited.")
    }
    
}

class UserMessage:Hashable {
    static func ==(lhs: UserMessage, rhs: UserMessage) -> Bool {
        return lhs.user == rhs.user
    }
    
    var hashValue: Int {
        return user.hashValue
    }
    
    let destinations:[String]
    let subject:String
    let user:User
    let message:String
    
    init(destination:String , user:User , message:String) {
        self.destinations = [destination]
        self.user = user
        self.message = message
        self.subject = "--"
    }
    
    init(json: [String: Any] , user:User) throws {
        
        guard let destination = json["destination"] as? String, let message = json["message"] as? String, let subject = json["subject"] as? String else { throw UserError.failedToCreate }
        
        self.subject = subject
        self.destinations = UserMessage.findDestinations(from: destination)
        self.message = message
        self.user = user
        
        print("User Message with email(user): " , user.email , "and destinations: , ", self.destinations ," inited.")
    }
    
    static func findDestinations(from:String) -> [String] {
        return from.components(separatedBy: ",")
    }
    
    func sendEmail() -> Bool{
        let smtpUrl = typeOfEmail().rawValue
        let client = SMTPClient(url: smtpUrl, username: user.email, password:user.password)
        let email = EMail(client: client)
        email.subject = subject
        email.from = Recipient(name: "Client", address: user.email)
        email.content = message
        for address in destinations {
            email.to.append(Recipient(address: address))
        }
        var wait = true
        var sent = true
        do {
            try email.send { code, header, body in
                print("response code: \(code)")
                print("response header: \(header)")
                print("response body: \(body)")
                if header.contains(string: "failed") || header.contains(string: "fail") || code == 67 {
                    sent = false
                }
                wait = false
            }//end send
        }catch(let err) {
            print("Failed to send: \(err)")
        }
        
        while(wait) {
            sleep(1)
        }
        
        print("done!")
        
        return sent        
    }
    
    func typeOfEmail() -> smtpServers {
        let email = user.email
        if email.contains(string: "gmail") {
            return .gmail
        } else {
            return .yahoo
        }
    }
    
    enum smtpServers:String {
        case gmail = "smtps://smtp.gmail.com"
        case yahoo = "smtps://smtp.mail.yahoo.com"
    }
}


