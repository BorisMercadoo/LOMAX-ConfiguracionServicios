set -e
cd /work
rm -rf build function.zip
pip install --no-cache-dir --retries 5 --default-timeout 60 pillow -t build
cp handler.py build/
python -c "import shutil; shutil.make_archive('function','zip','build')"
ls -l function.zip