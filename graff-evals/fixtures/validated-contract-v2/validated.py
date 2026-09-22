"""Validated / Invalid — incomplete. Fix the SPEC.md contract."""


class Valid:
    __match_args__ = ("value",)

    def __init__(self, value):
        self.value = value

    def bind(self, fn):
        return fn(self.value)

    def apply(self, other):
        if isinstance(other, Invalid):
            return other
        return Valid(self.value(other.value))

    def swap(self):
        # BUG: does not wrap in a 1-tuple
        return Invalid(self.value)

    def alt(self, fn):
        return self

    @classmethod
    def from_validated(cls, v):
        return v

    def __eq__(self, other):
        return type(other) is Valid and other.value == self.value

    def __repr__(self):
        return f"Valid({self.value!r})"


class Invalid:
    __match_args__ = ("errors",)

    def __init__(self, errors):
        if isinstance(errors, tuple):
            self.errors = errors
        elif isinstance(errors, (list, set)):
            self.errors = tuple(errors)
        else:
            # BUG: single error stored bare instead of 1-tuple
            self.errors = errors

    @classmethod
    def from_failure(cls, err):
        return cls(err)

    def bind(self, fn):
        return self

    def apply(self, other):
        # BUG: does not concatenate when other is Invalid
        if isinstance(other, Invalid):
            return self
        return self

    def swap(self):
        return Valid(self.errors)

    def alt(self, fn):
        if isinstance(self.errors, tuple):
            return Invalid(tuple(fn(e) for e in self.errors))
        return Invalid(fn(self.errors))

    @classmethod
    def from_validated(cls, v):
        return v

    def __eq__(self, other):
        return type(other) is Invalid and other.errors == self.errors

    def __repr__(self):
        return f"Invalid({self.errors!r})"


def combine(a, b, fn):
    if isinstance(a, Valid) and isinstance(b, Valid):
        return Valid(fn(a.value, b.value))
    if isinstance(a, Invalid) and isinstance(b, Invalid):
        return a.apply(b)
    return a if isinstance(a, Invalid) else b


def combine_n(items, fn):
    errs = []
    vals = []
    for it in items:
        if isinstance(it, Invalid):
            e = it.errors if isinstance(it.errors, tuple) else (it.errors,)
            errs.extend(e)
        else:
            vals.append(it.value)
    if errs:
        return Invalid(tuple(errs))
    return Valid(fn(*vals))
