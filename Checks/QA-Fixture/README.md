# Isolated browser QA

These are synthetic pages and profile-generation scripts. They contain no user profile, session, history, cookies, credentials, or generated application. No third-party service is required. The server binds only to `127.0.0.1:8765`; the `localhost` link deliberately exercises a different hostname on the same local server.

Run the following from the Curve source directory in a logged-in macOS desktop session. Quit **Curve QA** and verify its process has exited before regenerating its state or replacing the QA app. A still-closing process can otherwise save old state over the fresh fixture.

1. Build the normal app with `./build.sh`.
2. Run `python3 Checks/QA-Fixture/create-seed.py`. It writes a synthetic profile under `.build/qa-fixture/profile`.
3. Start `python3 Checks/QA-Fixture/serve.py` in a separate terminal. It serves only this fixture's `site` directory. Stop the server after validation.
4. Run `zsh Checks/QA-Fixture/build-qa.sh`. It packages the built binary as `.build/qa-fixture/Curve QA.app` with a separate bundle identity, `com.toymakers.curve.qa`, and an explicit synthetic data-directory key.
5. Open `.build/qa-fixture/Curve QA.app` and execute [E2E-CHECKLIST.md](../../E2E-CHECKLIST.md). Record visible outcomes and state evidence. Routing/action assertions alone do not prove live-window execution.

Generated profiles and apps stay under `.build` and are not part of the source fixture. The normal Curve/Arc profiles are not used. QA browser cookies use the separate QA app identity. QA packaging assigns a timestamp build number so rapid rebuilds can be distinguished by Launch Services. The seed is marked as the current appearance version, so it needs no legacy appearance migration.

To use another built app, pass its path as the first argument to `build-qa.sh`. An optional second argument sets the runtime directory; generate the matching seed with `create-seed.py --profile /absolute/runtime/directory/profile`.

Studio starts on **QA Navigation**, with two favorites, two unfiled pins, two nested pins under **Resources / Reading**, and five Today tabs. Research has one pin and one Today tab; Focus has the native start page. One archived tab supports restore testing. Fixed tab IDs make state comparisons possible without personal data.

Pages include same-site history navigation, another-hostname navigation, target-blank and Peek links, Find text, a zoom ruler, inputs and rich editing, native JavaScript dialogs, a disposable download, and a file input that only displays the selected filename locally. The fixture does not upload any file.
