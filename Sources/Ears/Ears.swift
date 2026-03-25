import ArgumentParser

@main
struct Ears: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ears",
        abstract: "Capture and transcribe audio from any macOS app.",
        subcommands: [
            Listen.self,
            Stop.self,
            Status.self,
            Setup.self,
        ]
    )
}
