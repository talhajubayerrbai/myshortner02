import random
import string

CODE_CHARS = string.ascii_letters + string.digits
CODE_LENGTH = 7


def generate_code() -> str:
    return "".join(random.choices(CODE_CHARS, k=CODE_LENGTH))
