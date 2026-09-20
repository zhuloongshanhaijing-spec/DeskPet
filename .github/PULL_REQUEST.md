## Pull Request checklist

Please go through these steps before you submit a PR.

1. Make sure your PR is not a duplicate of an existing PR or issue.

2. Make sure that:

    a. You have tested the code yourself — the app builds and works as intended:
       ```bash
       xcodebuild -project deskpet.xcodeproj -scheme deskpet \
         -configuration Release -destination 'generic/platform=macOS' \
         CODE_SIGNING_ALLOWED=NO build
       ```

    b. UI changes include screenshots or screen recordings showing the change.

3. **After** these steps, you're ready to open a pull request:

    a. Your pull request should target the `main` branch of this repository.

    b. Give a descriptive title to your PR.

    c. Describe your changes in detail, including the motivation and approach.

    d. Put `closes #XXXX` in your description to link your PR to the issue(s) that it fixes (if any).

IMPORTANT: Please review the [CONTRIBUTING.md](../CONTRIBUTING.md) file for detailed contributing guidelines.
