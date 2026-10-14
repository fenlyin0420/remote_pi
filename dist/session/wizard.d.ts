/**
 * Minimal wizard for `/remote-pi join` with no argument.
 *
 * The Pi SDK `ExtensionUIContext.select` accepts a title and string options
 * and returns the chosen option. Wizard offers existing sessions + an "explicit
 * create" sentinel. If user picks the sentinel, prompts for a fresh name via
 * `select`-with-option-other (Pi's "Other" escape hatch). Returns the picked
 * session name, or null if user cancelled.
 */
export interface WizardUI {
    select(title: string, options: string[]): Promise<string | undefined>;
}
export declare function joinWizard(ui: WizardUI, defaultName: string): Promise<string | null>;
