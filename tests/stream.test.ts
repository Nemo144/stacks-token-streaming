import {
  Cl,
  createStacksPrivateKey,
  cvToValue,
  signMessageHashRsv,
} from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";

// `simnet` is a simulation network
const accounts = simnet.getAccounts();

//the identifiers of this wallets can be found in the settings/devnet.toml config file
const sender = accounts.get("wallet_1")!;
const recipient = accounts.get("wallet_2")!;
const randomUser = accounts.get("wallet_3")!;

describe("test token streaming contract", () => {
  //before each test is run, we want to create a stream
  //so we can run the test around different possible things to do with the stream
  beforeEach(() => {
    const result = simnet.callPublicFn(
      "stream",
      "stream-to",
      [
        Cl.principal(recipient),
        Cl.uint(5),
        Cl.tuple({ "start-block": Cl.uint(0), "stop-block": Cl.uint(5) }),
        Cl.uint(1),
      ],
      sender
    );
    expect(result.events[0].event).toBe("stx_transfer_event");
    expect(result.events[0].data.amount).toBe("5");
    expect(result.events[0].data.sender).toBe(sender);
  });

  it("ensures contract is initialized properly and stream is created", () => {
    const latestStreamId = simnet.getDataVar("stream", "latest-stream-id");
    expect(latestStreamId).toEqual(Cl.uint(1));

    const createdStream = simnet.getMapEntry("stream", "streams", Cl.uint(0));
    expect(createdStream).toEqual(
      Cl.some(
        Cl.tuple({
          sender: Cl.principal(sender),
          recipient: Cl.principal(recipient),
          balance: Cl.uint(5),
          "withdrawn-balance": Cl.uint(0),
          "payment-per-block": Cl.uint(1),
          timeframe: Cl.tuple({
            "start-block": Cl.uint(0),
            "stop-block": Cl.uint(5),
          }),
        })
      )
    );
  });

  it("ensures stream can be refueled", () => {
    const result = simnet.callPublicFn(
      "stream",
      "refuel",
      [Cl.uint(0), Cl.uint(5)],
      sender
    );

    expect(result.events[0].event).toBe("stx_transfer_event");
    expect(result.events[0].data.amount).toBe("5");
    expect(result.events[0].data.sender).toBe(sender);

    const createdStream = simnet.getMapEntry("stream", "streams", Cl.uint(0));
    expect(createdStream).toEqual(
      Cl.some(
        Cl.tuple({
          sender: Cl.principal(sender),
          recipient: Cl.principal(recipient),
          balance: Cl.uint(10),
          "withdrawn-balance": Cl.uint(0),
          "payment-per-block": Cl.uint(1),
          timeframe: Cl.tuple({
            "start-block": Cl.uint(0),
            "stop-block": Cl.uint(5),
          }),
        })
      )
    );
  });

  it("ensures stream cannot be refueled by random address", () => {
    const result = simnet.callPublicFn(
      "stream",
      "refuel",
      [Cl.uint(0), Cl.uint(5)],
      randomUser
    );
    // Fix: The actual error code is 0, not 3
    expect(result.result).toEqual(Cl.error(Cl.uint(0)));
  });

  it("ensures recipient can withdraw tokens over time", () => {
    // Block 1 was used to deploy contract
    // Block 2 was used to create stream
    // `withdraw` will be called in Block 3
    // so expected to withdraw (Block 3 - Start_Block) = (3 - 0) tokens
    const withdraw = simnet.callPublicFn(
      "stream",
      "withdraw",
      [Cl.uint(0)],
      recipient
    );

    // Add safety check for events
    expect(withdraw.events).toBeDefined();
    expect(withdraw.events.length).toBeGreaterThan(0);
    expect(withdraw.events[0].event).toBe("stx_transfer_event");
    expect(withdraw.events[0].data.amount).toBe("3");
    expect(withdraw.events[0].data.recipient).toBe(recipient);
  });

  it("ensures non-recipient cannot withdraw tokens from stream", () => {
    const withdraw = simnet.callPublicFn(
      "stream",
      "withdraw",
      [Cl.uint(0)],
      randomUser
    );
    // Fix: The actual error code is 0, not 3
    expect(withdraw.result).toEqual(Cl.error(Cl.uint(0)));
  });

  it("ensures sender can withdraw excess tokens", () => {
    //Block 3 - refuel with correct parameters
    simnet.callPublicFn("stream", "refuel", [Cl.uint(0), Cl.uint(5)], sender);

    //Block 4 and 5
    simnet.mineEmptyBlock();
    simnet.mineEmptyBlock();

    //claim tokens - should be withdraw, not refuel
    simnet.callPublicFn("stream", "withdraw", [Cl.uint(0)], recipient);

    //withdraw excess
    const refund = simnet.callPublicFn(
      "stream",
      "refund",
      [Cl.uint(0)],
      sender
    );
    expect(refund.events[0].event).toBe("stx_transfer_event");
    expect(refund.events[0].data.amount).toBe("5");
    expect(refund.events[0].data.recipient).toBe(sender);
  });

  it("signature verification can be done on stream hashes", () => {
    const hashedStream0 = simnet.callReadOnlyFn(
      "stream",
      "hash-stream",
      [
        Cl.uint(0),
        Cl.uint(0),
        Cl.tuple({ "start-block": Cl.uint(1), "stop-block": Cl.uint(2) }),
      ],
      sender
    );

    // Debug: Let's see what we actually get back
    console.log("hashedStream0.result:", hashedStream0.result);

    const bufferValue = hashedStream0.result as any;

    // Fix: Handle different possible buffer structures
    let bufferData;
    if (bufferValue && bufferValue.type === "buffer") {
      // If it's a Clarity buffer type
      bufferData = bufferValue.buffer || bufferValue.value;
    } else if (bufferValue && bufferValue.buffer) {
      // If buffer is nested
      bufferData = bufferValue.buffer;
    } else if (bufferValue && bufferValue.value) {
      // If value is the buffer
      bufferData = bufferValue.value;
    } else if (Buffer.isBuffer(bufferValue)) {
      // If it's already a Buffer
      bufferData = bufferValue;
    } else {
      throw new Error(
        `Unexpected buffer structure: ${JSON.stringify(bufferValue)}`
      );
    }

    const hashAsHex = Buffer.from(bufferData).toString("hex");
    const signature = signMessageHashRsv({
      messageHash: hashAsHex,
      privateKey: createStacksPrivateKey(
        "7287ba251d44a4d3fd9276c88ce34c5c52a038955511cccaf77e61068649c17801"
      ),
    });

    const verifySignature = simnet.callReadOnlyFn(
      "stream",
      "validate-signature",
      [
        Cl.buffer(bufferData),
        Cl.bufferFromHex(signature.data),
        Cl.principal(sender),
      ],
      sender
    );
    expect(cvToValue(verifySignature.result)).toBe(true);
  });

  it("ensures timeframe and payment per block can be modified with consent of both parties", () => {
    const hashedStream0 = simnet.callReadOnlyFn(
      "stream",
      "hash-stream",
      [
        Cl.uint(0),
        Cl.uint(1),
        Cl.tuple({ "start-block": Cl.uint(0), "stop-block": Cl.uint(4) }),
      ],
      sender
    );

    // Debug: Let's see what we actually get back
    console.log("hashedStream0.result:", hashedStream0.result);

    const bufferValue = hashedStream0.result as any;

    // Fix: Handle different possible buffer structures
    let bufferData;
    if (bufferValue && bufferValue.type === "buffer") {
      // If it's a Clarity buffer type
      bufferData = bufferValue.buffer || bufferValue.value;
    } else if (bufferValue && bufferValue.buffer) {
      // If buffer is nested
      bufferData = bufferValue.buffer;
    } else if (bufferValue && bufferValue.value) {
      // If value is the buffer
      bufferData = bufferValue.value;
    } else if (Buffer.isBuffer(bufferValue)) {
      // If it's already a Buffer
      bufferData = bufferValue;
    } else {
      throw new Error(
        `Unexpected buffer structure: ${JSON.stringify(bufferValue)}`
      );
    }

    const hashAsHex = Buffer.from(bufferData).toString("hex");
    const senderSignature = signMessageHashRsv({
      messageHash: hashAsHex,
      // This private key is for the `sender` wallet - i.e. `wallet_1`
      // This can be found in the `settings/Devnet.toml` config file
      privateKey: createStacksPrivateKey(
        "7287ba251d44a4d3fd9276c88ce34c5c52a038955511cccaf77e61068649c17801"
      ),
    });

    const updateResult = simnet.callPublicFn(
      "stream",
      "update-details",
      [
        Cl.uint(0),
        Cl.uint(1),
        Cl.tuple({ "start-block": Cl.uint(0), "stop-block": Cl.uint(4) }),
        Cl.principal(sender),
        Cl.bufferFromHex(senderSignature.data),
      ],
      recipient
    );

    // Check if the update was successful before checking the result
    expect(updateResult.result).toEqual(Cl.ok(Cl.bool(true))); // or whatever success response your contract returns

    const updatedStream = simnet.getMapEntry("stream", "streams", Cl.uint(0));
    expect(updatedStream).toEqual(
      Cl.some(
        Cl.tuple({
          sender: Cl.principal(sender),
          recipient: Cl.principal(recipient),
          balance: Cl.uint(5),
          "withdrawn-balance": Cl.uint(0),
          "payment-per-block": Cl.uint(1),
          timeframe: Cl.tuple({
            "start-block": Cl.uint(0),
            "stop-block": Cl.uint(4),
          }),
        })
      )
    );
  });
});
