"""Minimal Python file for verifying Claude Code's LSP tool works with pyright-lsp."""

from dataclasses import dataclass


@dataclass
class User:
    userid: str
    email: str
    verified: bool


def create_user(userid: str, email: str) -> User:
    return User(userid=userid, email=email, verified=False)


def verify_user(user: User) -> User:
    user.verified = True
    return user


def greet(user: User) -> str:
    return f"Hello, {user.email}"


def main() -> None:
    alice = create_user("u-001", "alice@example.com")
    alice = verify_user(alice)
    print(greet(alice))


if __name__ == "__main__":
    main()
