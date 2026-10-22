# Engineering decisions

## D-001 Real photo first

No full-image generative redraw. Identity, geometry, text and scene facts remain unchanged.

## D-002 Explainable recipe

Analysis creates structured evidence, decision creates parameters, renderer executes them. A
professional-looking JSON without corresponding pixel modules is not a feature.

## D-003 Multi-label context over one classifier label

V7 keeps semantic labels and derives independent lighting/subject/aesthetic dimensions. A single
primary strategy remains only for compatibility and UI summary.

## D-004 Verified local masks only

Person, face, captured skin and model-produced sky are semantic masks. Saliency is a generic
subject mask. Other regions remain unavailable until validated; luminance masks may adjust tone
but never pretend to identify an object.

## D-005 Bounded quality feedback

Quality validation may produce one issue-specific corrective recipe and one re-render. It must
not loop indefinitely or rerun Vision/Core ML.

## D-006 Reference works are constraints, not LUTs

User references guide highlight shape, light ratios, color credibility and texture constraints.
They are not copied, bundled into a public app, or used as universal numeric targets.

