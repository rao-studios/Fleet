import Foundation

/// The single prompt format shared by training and gated inference.
///
/// Training text and the inference prompt must agree exactly: the inference
/// prompt is a literal prefix of the training text, ending right where the
/// model is expected to start emitting `{`. Raw text is used rather than a chat
/// template so the tokens the LoRA saw during training are the tokens the gate
/// sees at decode time.
public enum PromptBuilder {

    /// Bump when the format changes so an adapter trained on the old wording is
    /// not silently driven with the new one.
    public static let version = 1

    private static let inputHeader = "INPUT:\n"
    private static let outputHeader = "\nOUTPUT:\n"

    /// The full example a LoRA is trained on.
    public static func trainingText(input: JSONValue, output: JSONValue) -> String {
        prompt(input: input) + JSONCanonical.serialize(output)
    }

    /// The prefix fed to the model at inference; generation continues from here.
    public static func prompt(input: JSONValue) -> String {
        inputHeader + JSONCanonical.serialize(input) + outputHeader
    }
}
