declare module "qrcode-terminal" {
  interface QROptions {
    small?: boolean;
  }
  function generate(
    input: string,
    opts: QROptions,
    callback?: (qrcode: string) => void,
  ): void;
  function generate(input: string, callback?: (qrcode: string) => void): void;
  function setErrorLevel(level: "L" | "M" | "Q" | "H"): void;
  export = { generate, setErrorLevel };
}
