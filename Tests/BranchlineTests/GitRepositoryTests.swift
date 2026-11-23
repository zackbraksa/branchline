import Testing

// Blocking Git fixture setup must not consume another test's operation deadline.
@Suite(.serialized)
struct GitRepositoryTests {}
