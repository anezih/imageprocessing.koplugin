.PHONY: android koxtoolchain linux clean

android:
	./native/build-android.sh

koxtoolchain:
	./native/build-koxtoolchain.sh

linux:
	./native/build-linux.sh

clean:
	rm -f libs/android/armeabi-v7a/libimageprocessing.so
	rm -f libs/android/arm64-v8a/libimageprocessing.so
	rm -f libs/kobo/kobov5/libimageprocessing.so
	rm -f libs/kindle/kindle-legacy/libimageprocessing.so
	rm -f libs/kindle/kindle/libimageprocessing.so
	rm -f libs/kindle/kindlehf/libimageprocessing.so
	rm -f libs/kindle/kindlepw2/libimageprocessing.so
	rm -f libs/pocketbook/pocketbook/libimageprocessing.so
	rm -f libs/linux/x86_64/libimageprocessing.so
