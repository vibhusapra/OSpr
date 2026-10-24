"""Require the pinned MLX stream's EOS acknowledgement before publishing text.

A balanced JSON object or plausible sentence can still be budget-truncated.
This gate checks completion, not the meaning or fidelity of the generated text.
"""
from numbers import Integral


class LocalCompletionError(ValueError):
    def __init__(self, message, *, output_limit=False):
        super().__init__(message)
        self.output_limit = output_limit


def completed_text(responses, *, eos_token_ids, max_tokens):
    error_message = ('Local text completion was not acknowledged by an end-of-sequence token. '
                     'Original text or previous notes are retained; split longer input and try again.')
    try:
        eos = set(eos_token_ids)
    except TypeError as error:
        raise LocalCompletionError(error_message) from error
    if (not eos or any(isinstance(token, bool) or not isinstance(token, Integral) or token < 0 for token in eos)
            or isinstance(max_tokens, bool) or not isinstance(max_tokens, Integral) or max_tokens <= 0):
        raise LocalCompletionError(error_message)
    try:
        iterator = iter(responses)
    except TypeError as error:
        raise LocalCompletionError(error_message) from error
    pieces, previous, terminal, limited = [], 0, False, False
    try:
        for response in iterator:
            text = getattr(response, 'text', None)
            count = getattr(response, 'generation_tokens', None)
            token = getattr(response, 'token', None)
            reason = getattr(response, 'finish_reason', None)
            if (terminal or not isinstance(text, str) or isinstance(count, bool)
                    or not isinstance(count, Integral) or count != previous+1 or count > max_tokens
                    or isinstance(token, bool) or not isinstance(token, Integral) or token < 0):
                raise LocalCompletionError(error_message)
            previous = int(count)
            pieces.append(text)
            if reason is None and token not in eos:
                continue
            if reason == 'length' and token not in eos and count == max_tokens:
                terminal, limited = True, True
                continue
            if reason != 'stop' or token not in eos:
                raise LocalCompletionError(error_message)
            terminal = True
        result = ''.join(pieces).strip()
        if limited:
            raise LocalCompletionError(error_message, output_limit=True)
        if not terminal or not result:
            raise LocalCompletionError(error_message)
        return dict(text=result, finish_reason='stop', generation_tokens=previous)
    finally:
        # Close early failures too: stream_generate holds MLX's wired-memory
        # context across yields. Leaving a generator suspended must not leak it.
        close = getattr(iterator, 'close', None)
        if callable(close):
            try:
                close()
            except Exception as error:
                raise LocalCompletionError(error_message) from error
