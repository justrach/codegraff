from config import DB
from store import load
from ui import render

def main():
    print(render(load(DB)))

if __name__ == "__main__":
    main()
