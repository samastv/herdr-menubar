import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let client = HerdrClient()
let status = StatusController(client: client)
client.start()

app.run()
