# DogeOS SDK bundle (site/dogeos.js + site/dogeos.css)

Built from entry.jsx with @dogeos/dogeos-sdk 4.0.6, React 18.3.1 and wagmi (pnpm, because the SDK's
dependencies use pnpm catalogs):

    pnpm add @dogeos/dogeos-sdk@4.0.6 wagmi react@18.3.1 react-dom@18.3.1 esbuild
    npx esbuild entry.jsx --bundle --minify --format=iife --platform=browser --target=es2020 --jsx=automatic \
      --define:process.env.NODE_ENV='"production"' --define:global=globalThis \
      --loader:.woff=dataurl --loader:.woff2=dataurl --loader:.png=dataurl --loader:.svg=dataurl \
      --external:mppx/client --outfile=dogeos.js

It exposes window.CavDoge.connect(cfg) / restore(cfg) / disconnect(), which return an EIP-1193 provider.
