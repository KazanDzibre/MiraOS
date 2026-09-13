Widgets here are the only things allowed to know what Mira looks like.

Two rules that are easy to break by accident:

- Every control is a `MiraFocusable`. Rolling your own focus handling is how
  the d-pad quietly stops reaching something.
- No colour or size literals - they belong in `core/tokens.dart`. A literal here
  drifts away from the design canvas within a week.
